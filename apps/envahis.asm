; ===================================================================
; ENVAHIS.ASM - Envahis pour OSM-VISION
; ===================================================================
; Application d'OSM-VISION, partie du modèle apps/mire.asm : liée à
; $4000, contrôle de version, sortie par RTS sans effacer l'écran.
;
; Graphismes : 28 glyphes en page 1 de video/font_osm39.bin ($2B-$3F,
; $48-$4E), réservés dans lib/ui.inc.
;
; Commandes : flèches gauche/droite (on peut les garder enfoncées),
; Espace pour tirer, Echap pour quitter.
;
; RENDU. Le terrain (58 x 20 cases, intérieur de la fenêtre) existe deux
; fois en RAM : Want (ce qu'on veut afficher) et Disp (ce qui est à
; l'écran). A chaque trame :
;   1. Update fait avancer le jeu et marque les rangées touchées (Dirty) ;
;   2. Compose recompose chaque rangée marquée dans Want, d'après l'état
;      du jeu, la compare à Disp et met les seules cases différentes dans
;      une file d'écriture ;
;   3. juste après le VSYNC, Apply_Queue écrit la file en VRAM, IRQ
;      masquées, APPLY_MAX cases au plus par trame (le reste à la trame
;      suivante ; la logique attend que la file soit vide).
; Recomposer une rangée entière règle tous les chevauchements (tir sur
; un envahisseur, explosion sur un bouclier) sans cas particulier.
; Les écritures VRAM sont directes, comme le rendu de BRIQUES : un
; vis_PutCell par case serait trop lent pour un jeu.
;
; CLAVIER. scan_keyboard ne rend la main qu'au RELÂCHEMENT d'une touche :
; impossible de garder une flèche enfoncée. Poll_Keys lit donc les octets
; PS/2 bruts (SCAN_CODE, posé par la NMI) : E0 = touche étendue, F0 =
; relâchement. Une touche gardée est entretenue par la répétition
; automatique du clavier ; si un relâchement se perd, elle se relâche
; seule après KEY_TIMEOUT trames.
;
; Cases vides : UI_SPACE / COLOR_WIN (premier plan non nul : voir
; AGENTS.md, défaut des cases au premier plan 0).
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"
    include "../lib/ui.inc"
    include "../lib/vis.inc"
    include "../lib/snd.inc"

    export App_Start

; Services d'OSM-VISION utilisés : jusqu'à vis_Sound_Stop
VIS_REQUIS      equ (vis_Sound_Stop/2)+1

; --- Fenêtre et terrain ---
WIN_X           equ 10
WIN_Y           equ 1           ; (la ligne 0 était hors écran avant le BIOS 80 x 30)
WIN_W           equ 60
WIN_H           equ 23
F_X             equ WIN_X+1     ; terrain = intérieur, sous le filet du titre
F_Y             equ WIN_Y+2
F_W             equ WIN_W-2     ; 58 colonnes
F_H             equ WIN_H-3     ; 20 rangées
F_SIZE          equ F_W*F_H
BLANK_C         equ UI_SPACE
BLANK_A         equ COLOR_WIN

; --- Rangées du terrain (0 = en haut) ---
STATUS_Y        equ 0           ; score et vies
UFO_Y           equ 1           ; soucoupe mystère
INV_Y0          equ 2           ; première rangée d'envahisseurs
SHIELD_Y        equ 15
INVADE_Y        equ 17          ; une rangée vivante ici : invasion
CAN_Y           equ 18
MSG_Y           equ 8           ; messages de fin de partie

; --- Envahisseurs ---
INV_COLS        equ 11
INV_ROWS        equ 5
INV_N           equ INV_COLS*INV_ROWS
INV_PITCH       equ 4           ; 2 cases de dessin + 2 d'écart
INV_SPAN        equ (INV_COLS-1)*INV_PITCH+2
INV_X0          equ (F_W-INV_SPAN)/2
WAVE_DROP_MAX   equ 3           ; chaque vague part une rangée plus bas, 3 au plus

; --- Joueur, tirs, boucliers ---
CAN_W           equ 3
EB_N            equ 3           ; tirs ennemis simultanés
EX_N            equ 4           ; explosions simultanées
SHIELD_N        equ 4
SHIELD_W        equ 4

; --- Glyphes (page 1 de video/font_osm39.bin, sprites de la borne
;     doublés en hauteur) et attributs : bit 7 = page 1, fond noir,
;     premier plan non nul ---
CHR_CALMAR      equ $2B         ; 2 cellules ; position 2 = +2
CHR_CRABE       equ $2F
CHR_POULPE      equ $33
CHR_CAN_L       equ $37         ; canon : 3 cellules
CHR_CAN_M       equ $38
CHR_CAN_R       equ $39
CHR_PBUL        equ $3A         ; tir du joueur
CHR_EBUL        equ $3B         ; tir ennemi (zigzag), rangées paires
CHR_EBUL2       equ $49         ; même zigzag décalé, rangées impaires
CHR_EXPL        equ $3C         ; explosion : 2 cellules
CHR_SH_PLEIN    equ $3E         ; bouclier : plein, rongé par le haut,
CHR_SH_HAUT     equ $4D         ; rongé par le bas, troué, ruiné
CHR_SH_BAS      equ $4E
CHR_SH_TROUE    equ $3F
CHR_SH_RUINE    equ $48
CHR_UFO         equ $4A         ; soucoupe : 3 cellules
ATTR_UFO        equ $8C         ; rouge vif
UFO_W           equ 3
ATTR_CAN        equ $8A         ; vert vif
ATTR_PBUL       equ $8F         ; blanc
ATTR_EBUL       equ $8E         ; jaune vif
ATTR_EXPL       equ $8C         ; rouge vif
ATTR_SHIELD     equ $82         ; vert

; --- Rendu ---
QCAP            equ 200         ; capacité de la file d'écriture
APPLY_MAX       equ 40          ; cases écrites par trame au plus
KEY_TIMEOUT     equ 40          ; trames sans répétition : touche relâchée

; --- États ---
ST_PLAY         equ 0
ST_DEAD         equ 1           ; canon détruit, pause
ST_OVER         equ 2           ; partie finie

ASCII_0         equ $30         ; lib/str.asm (Dec16)

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
    CLR     KeyLeft
    CLR     KeyRight
    CLR     KbE0
    CLR     KbRel
    CLR     FireReq
    CLR     QuitReq
    CLR     EscUp
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #WIN_X
    LDB     #WIN_Y
    LDW     #(WIN_W*256)+WIN_H
    LDY     #TxtTitre
    JSR     [VIS_TABLE+vis_Window]
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     Init_Display        ; Disp = intérieur de fenêtre, tout à redessiner
    JSR     Load_HiScore
    JSR     New_Game

; -------------------------------------------------------------------
; Boucle principale : une trame par tour
; -------------------------------------------------------------------
Main_Loop:
    JSR     Wait_Frame          ; lit le clavier en attendant le VSYNC
    JSR     Apply_Queue         ; tout de suite après le VSYNC
    TST     QuitReq
    LBNE    Quit
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

; Vide les octets PS/2 reçus : met à jour KeyLeft/KeyRight (compteurs :
; non nul = enfoncée), FireReq et QuitReq (appuis), EscUp (relâchement).
Poll_Keys:
    TST     >NEW_CODE
    BEQ     PK_End
    CLR     >NEW_CODE
    LDA     >SCAN_CODE
    CMPA    #$E0
    BNE     PK_NotE0
    STA     KbE0
    BRA     Poll_Keys
PK_NotE0:
    CMPA    #$F0
    BNE     PK_Code
    STA     KbRel
    BRA     Poll_Keys
PK_Code:
    LDB     KbRel               ; B <> 0 : relâchement
    TST     KbE0
    BEQ     PK_Normal
    CMPA    #$6B                ; E0 6B : flèche gauche
    BNE     PK_E0b
    LDX     #KeyLeft
    BRA     PK_Held
PK_E0b:
    CMPA    #$74                ; E0 74 : flèche droite
    BNE     PK_Done
    LDX     #KeyRight
PK_Held:
    TSTB
    BNE     PK_Up
    LDA     #KEY_TIMEOUT
    STA     ,X
    BRA     PK_Done
PK_Up:
    CLR     ,X
    BRA     PK_Done
PK_Normal:
    CMPA    #$29                ; Espace
    BNE     PK_Esc
    TSTB
    BNE     PK_Done
    LDA     #1
    STA     FireReq
    BRA     PK_Done
PK_Esc:
    CMPA    #$76                ; Echap
    BNE     PK_Done
    TSTB
    BEQ     PK_EscDown
    LDA     #1
    STA     EscUp
    BRA     PK_Done
PK_EscDown:
    LDA     #1
    STA     QuitReq
PK_Done:
    CLR     KbE0
    CLR     KbRel
    BRA     Poll_Keys
PK_End:
    RTS

; -------------------------------------------------------------------
; Parties et vagues
; -------------------------------------------------------------------
New_Game:
    CLR     Score
    CLR     Score+1
    LDA     #3
    STA     Lives
    CLR     Wave
    CLR     NewRecord
    JSR     New_Wave
    CLR     FireReq
    RTS

New_Wave:
    LDX     #Alive
    LDB     #INV_N
    LDA     #1
NW_Alive:
    STA     ,X+
    DECB
    BNE     NW_Alive
    LDA     #INV_N
    STA     AliveCount
    LDX     #RowX
    LDY     #RowY
    LDA     Wave                ; difficulté : départ plus bas à chaque vague
    CMPA    #WAVE_DROP_MAX
    BLS     NW_Drop
    LDA     #WAVE_DROP_MAX
NW_Drop:
    ADDA    #INV_Y0
    LDB     #INV_ROWS
NW_Rows:
    PSHS    A
    LDA     #INV_X0
    STA     ,X+
    PULS    A
    STA     ,Y+
    ADDA    #2                  ; une rangée vide entre deux rangées
    DECB
    BNE     NW_Rows
    LDX     #RowFrame
    LDB     #INV_ROWS
NW_Frame:
    CLR     ,X+
    DECB
    BNE     NW_Frame
    LDA     #1
    STA     Dir
    CLR     Descending
    LDA     #INV_ROWS-1         ; on commence par la rangée du bas
    STA     CurRow
    LDA     #1
    STA     MoveTimer
    LDA     #60
    STA     EFireTimer
    LDX     #Shield
    LDB     #SHIELD_N*SHIELD_W
    LDA     #SH_PLEIN
NW_Shield:
    STA     ,X+
    DECB
    BNE     NW_Shield
    LDA     #(F_W-CAN_W)/2
    STA     CanX
    CLR     PBActive
    LDX     #EBActive
    LDB     #EB_N
NW_EB:
    CLR     ,X+
    DECB
    BNE     NW_EB
    LDX     #ExTimer
    LDB     #EX_N
NW_EX:
    CLR     ,X+
    DECB
    BNE     NW_EX
    CLR     SndBusy
    CLR     MarchIdx
    CLR     UfoActive
    CLR     UfoPtsTimer
    JSR     Ufo_Reload
    LDA     #ST_PLAY
    STA     State
    JSR     Mark_All
    RTS

; -------------------------------------------------------------------
; Logique, une trame
; -------------------------------------------------------------------
Update:
    LDA     State
    CMPA    #ST_OVER
    LBEQ    Upd_Over
    TST     KeyLeft             ; touches gardées : délai de sécurité
    BEQ     U_KL
    DEC     KeyLeft
U_KL:
    TST     KeyRight
    BEQ     U_KR
    DEC     KeyRight
U_KR:
    INC     Frame
    TST     SndBusy
    BEQ     U_Snd
    DEC     SndBusy
U_Snd:
    JSR     Upd_Explosions
    LDA     State
    CMPA    #ST_DEAD
    LBEQ    Upd_Dead
    JSR     Upd_Player
    JSR     Upd_PBullet
    JSR     Upd_Ufo
    JSR     Upd_Envahis
    JSR     Upd_EBullets
    RTS

; Canon détruit : tout est figé jusqu'à la fin de la pause.
Upd_Dead:
    DEC     DeadTimer
    BNE     UD_End
    LDB     #CAN_Y
    JSR     Mark_Row
    TST     Lives
    BEQ     UD_Over
    LDA     #(F_W-CAN_W)/2
    STA     CanX
    LDA     #ST_PLAY
    STA     State
    CLR     FireReq
UD_End:
    RTS
UD_Over:
    JSR     Game_Over
    RTS

Game_Over:
    LDA     #ST_OVER
    STA     State
    CLR     FireReq
    LDB     #MSG_Y
    JSR     Mark_Row
    LDB     #MSG_Y+2
    JSR     Mark_Row
    LDB     #MSG_Y+4
    JSR     Mark_Row
    LDX     #Sd_Over
    JSR     Snd_Play
    LDD     Score               ; record battu ?
    CMPD    HiScore
    BLS     GO_End
    STD     HiScore
    LDA     #1
    STA     NewRecord
    LDB     #STATUS_Y
    JSR     Mark_Row
    JSR     Save_HiScore
GO_End:
    RTS

; -------------------------------------------------------------------
; Meilleur score : fichier ENVAHIS.HI de 2 octets sur la carte
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
; sauve les 2 octets, puis rw : ce n'est pas un programme. Le BIOS doit
; avoir le correctif de FS_SaveFile du 9 oct. 2026 (secteur plein).
Save_HiScore:
    LDX     #HiName
    JSR     [table_function_ram+sys_FS_DeleteFile]   ; absent : sans importance
    LDA     >current_page       ; FS_SaveFile : page SOURCE dans A (sinon
    LDX     #HiName             ; il bascule la RAM sur une page quelconque)
    LDY     #HiScore
    LDU     #2
    JSR     [table_function_ram+sys_FS_SaveFile]
    BCS     SH_Fin
    LDX     #HiName
    LDA     #$06                ; rw
    JSR     [table_function_ram+sys_FS_SetAttributes]
SH_Fin:
    RTS

; Partie finie : Espace relance.
Upd_Over:
    TST     FireReq
    BEQ     UO_End
    CLR     FireReq
    JSR     New_Game
UO_End:
    RTS

; --- Canon : un pas toutes les deux trames, tir sur Espace ---
Upd_Player:
    LDA     Frame
    BITA    #1
    BNE     UP_Fire
    TST     KeyLeft
    BEQ     UP_Right
    LDA     CanX
    BEQ     UP_Right
    DECA
    STA     CanX
    LDB     #CAN_Y
    JSR     Mark_Row
UP_Right:
    TST     KeyRight
    BEQ     UP_Fire
    LDA     CanX
    CMPA    #F_W-CAN_W
    BHS     UP_Fire
    INCA
    STA     CanX
    LDB     #CAN_Y
    JSR     Mark_Row
UP_Fire:
    TST     FireReq
    BEQ     UP_End
    CLR     FireReq
    TST     PBActive            ; un seul tir à la fois, comme l'original
    BNE     UP_End
    LDA     CanX
    INCA
    STA     PBX
    LDA     #CAN_Y-1
    STA     PBY
    LDA     #1
    STA     PBActive
    LDB     PBY
    JSR     Mark_Row
    LDX     #Sd_Shot
    JSR     Snd_Play
UP_End:
    RTS

; --- Tir du joueur : une rangée par trame ---
Upd_PBullet:
    TST     PBActive
    BEQ     UPB_End
    LDB     PBY
    JSR     Mark_Row
    DEC     PBY
    LDB     PBY
    CMPB    #STATUS_Y+1
    BLO     UPB_Off             ; arrivé en haut
    JSR     Mark_Row
    CLR     HitFromAbove        ; le tir monte : bouclier rongé par le bas
    LDA     PBX
    LDB     PBY
    JSR     Shield_Hit
    BCS     UPB_Off
    LDA     PBX
    LDB     PBY
    JSR     Envahisseur_Hit
    BCS     UPB_Off
    LDA     PBX
    LDB     PBY
    JSR     Ufo_Hit
    BCS     UPB_Off
UPB_End:
    RTS
UPB_Off:
    CLR     PBActive
    RTS

; A = colonne, B = rangée : bouclier touché ? Si oui, la case passe à
; l'état suivant selon le sens du tir (HitFromAbove) et C = 1.
Shield_Hit:
    CMPB    #SHIELD_Y
    BNE     SH_No
    STA     HitCol
    CLRB                        ; B = numéro de bouclier
SH_Loop:
    LDX     #ShieldX
    LDA     HitCol
    SUBA    B,X                 ; A = décalage dans le bouclier
    BCS     SH_Next             ; à gauche du bouclier
    CMPA    #SHIELD_W
    BHS     SH_Next
    PSHS    A
    TFR     B,A
    ASLA
    ASLA                        ; bouclier * 4
    ADDA    ,S+
    LDX     #Shield
    LDB     A,X                 ; état de la case
    BEQ     SH_No               ; trou : le tir passe
    PSHS    A                   ; indice de la case
    LDX     #NextBelow
    TST     HitFromAbove
    BEQ     SH_Tbl
    LDX     #NextAbove
SH_Tbl:
    LDB     B,X                 ; nouvel état
    PULS    A
    LDX     #Shield
    STB     A,X
    LDB     #SHIELD_Y
    JSR     Mark_Row
    ORCC    #%00000001
    RTS
SH_Next:
    INCB
    CMPB    #SHIELD_N
    BLO     SH_Loop
SH_No:
    ANDCC   #%11111110
    RTS

; A = colonne, B = rangée : envahisseur touché ? Si oui, il meurt
; (score, explosion, son) et C = 1.
Envahisseur_Hit:
    STA     HitCol
    STB     HitRow
    CLRB                        ; B = rangée d'envahisseurs 0..4
IH_Loop:
    LDX     #RowY
    LDA     B,X
    CMPA    HitRow
    BNE     IH_Next
    LDX     #RowX
    LDA     HitCol
    SUBA    B,X                 ; A = décalage depuis la 1re colonne
    BCS     IH_Next
    CMPA    #INV_SPAN
    BHS     IH_Next
    PSHS    A
    ANDA    #3
    CMPA    #2                  ; dans l'écart entre deux envahisseurs
    PULS    A
    BHS     IH_Next
    LSRA
    LSRA                        ; A = colonne d'envahisseur 0..10
    STA     HitInv
    PSHS    B
    LDA     #INV_COLS
    MUL                         ; D = rangée * 11 (B = rangée)
    ADDB    HitInv              ; B = indice 0..54
    LDX     #Alive
    ABX
    PULS    B
    TST     ,X
    BEQ     IH_Next             ; déjà mort : le tir passe
    CLR     ,X
    DEC     AliveCount
    LDX     #RowPts             ; points selon la rangée
    LDA     B,X
    ADDA    Score+1
    STA     Score+1
    BCC     IH_Pts
    INC     Score
IH_Pts:
    LDA     HitInv              ; explosion à la place de l'envahisseur
    ASLA
    ASLA
    LDX     #RowX
    ADDA    B,X
    LDB     HitRow
    JSR     Add_Explosion
    LDB     #STATUS_Y
    JSR     Mark_Row
    LDX     #Sd_Kill
    JSR     Snd_Play
    ORCC    #%00000001
    RTS
IH_Next:
    INCB
    CMPB    #INV_ROWS
    BLO     IH_Loop
    ANDCC   #%11111110
    RTS

; --- Soucoupe mystère : traverse la rangée UFO_Y de temps en temps ---
Upd_Ufo:
    TST     UfoPtsTimer         ; affichage du bonus
    BEQ     UU_Wait
    DEC     UfoPtsTimer
    BNE     UU_Wait
    LDB     #UFO_Y
    JSR     Mark_Row
UU_Wait:
    TST     UfoActive
    BNE     UU_Move
    LDD     UfoTimer
    SUBD    #1
    STD     UfoTimer
    BNE     UU_End
    JSR     Ufo_Reload
    LDA     AliveCount          ; pas de soucoupe en fin de vague
    CMPA    #8
    BLO     UU_End
    JSR     Rand                ; de gauche ou de droite
    ANDA    #1
    BEQ     UU_FromLeft
    LDA     #F_W-UFO_W
    STA     UfoX
    LDA     #-1
    BRA     UU_Start
UU_FromLeft:
    CLR     UfoX
    LDA     #1
UU_Start:
    STA     UfoDir
    LDA     #1
    STA     UfoActive
    LDB     #UFO_Y
    JSR     Mark_Row
    LDX     #Sd_UfoIn
    JSR     Snd_Play
UU_Move:
    LDA     Frame               ; une colonne toutes les deux trames
    BITA    #1
    BNE     UU_End
    LDB     #UFO_Y
    JSR     Mark_Row
    LDA     UfoX
    ADDA    UfoDir
    BMI     UU_Off              ; sortie à gauche
    CMPA    #F_W-UFO_W
    BHI     UU_Off              ; sortie à droite
    STA     UfoX
UU_End:
    RTS
UU_Off:
    CLR     UfoActive
    RTS

; Prochaine soucoupe dans 15 à 19 s : 900 trames + 0 à 255 au hasard.
Ufo_Reload:
    JSR     Rand
    TFR     A,B
    CLRA
    ADDD    #900
    STD     UfoTimer
    RTS

; A = colonne, B = rangée : soucoupe touchée ? Si oui : bonus au hasard
; (50, 100, 150 ou 300), affiché à sa place, et C = 1.
Ufo_Hit:
    TST     UfoActive
    BEQ     UH_No
    CMPB    #UFO_Y
    BNE     UH_No
    SUBA    UfoX
    BCS     UH_No
    CMPA    #UFO_W
    BHS     UH_No
    CLR     UfoActive
    JSR     Rand
    ANDA    #3
    ASLA
    LDX     #UfoBonus
    LDD     A,X
    STD     UfoPts
    ADDD    Score
    STD     Score
    LDA     UfoX
    STA     UfoPtsX
    LDA     #60
    STA     UfoPtsTimer
    LDB     #UFO_Y
    JSR     Mark_Row
    LDB     #STATUS_Y
    JSR     Mark_Row
    LDX     #Sd_UfoHit
    JSR     Snd_Play
    ORCC    #%00000001
    RTS
UH_No:
    ANDCC   #%11111110
    RTS

; --- Envahisseurs : une rangée par pas, de bas en haut (effet d'onde) ---
Upd_Envahis:
    DEC     MoveTimer
    LBNE    UI_End
    LDA     AliveCount          ; plus ils sont rares, plus ils vont vite
    LSRA
    LSRA
    LSRA
    INCA
    STA     MoveTimer
    LDB     CurRow
    LDX     #RowY
    LDA     B,X
    STA     HitRow              ; ancienne rangée d'écran
    TST     Descending
    BEQ     UI_Side
    INCA                        ; descente d'une rangée
    STA     B,X
    PSHS    B
    LDB     HitRow
    JSR     Mark_Row
    PULS    B
    LDX     #RowY
    LDA     B,X
    CMPA    #SHIELD_Y           ; ils écrasent les boucliers
    BNE     UI_Mark
    JSR     Crush_Shields
    BRA     UI_Mark
UI_Side:
    LDX     #RowX
    LDA     B,X
    ADDA    Dir
    STA     B,X
UI_Mark:
    LDB     CurRow              ; la rangée change de position (animation)
    LDX     #RowFrame
    LDA     B,X
    EORA    #1
    STA     B,X
    LDX     #RowY
    LDB     CurRow
    LDB     B,X
    JSR     Mark_Row
    ; La rangée vient de bouger : si elle est arrivée SUR le tir du
    ; joueur, c'est un coup au but. Sans ce test, le tir ne vérifie qu'en
    ; montant, et une rangée qui se décale ou descend sous lui semble
    ; traversée (surtout les rangées du bas, qui bougent en premier).
    TST     PBActive
    BEQ     UI_Invade
    LDB     CurRow
    LDX     #RowY
    LDA     B,X
    CMPA    PBY
    BNE     UI_Invade
    LDA     PBX
    LDB     PBY
    JSR     Envahisseur_Hit
    BCC     UI_Invade
    CLR     PBActive
UI_Invade:
    ; invasion : une rangée vivante est arrivée au canon
    LDB     CurRow
    LDX     #RowY
    LDA     B,X
    CMPA    #INVADE_Y
    BLO     UI_Next
    JSR     Row_Alive
    BEQ     UI_Next
    LDA     #ST_DEAD            ; explosion du canon, puis fin de partie
    STA     State
    CLR     Lives
    LDA     #60
    STA     DeadTimer
    LDA     CanX
    LDB     #CAN_Y
    JSR     Add_Explosion
    LDX     #Sd_Dead
    JSR     Snd_Play
    RTS
UI_Next:
    DEC     CurRow
    BPL     UI_End
    ; fin d'un pas complet
    LDA     #INV_ROWS-1
    STA     CurRow
    TST     Descending
    BEQ     UI_Check
    CLR     Descending
    NEG     Dir
UI_Check:
    TST     AliveCount
    BNE     UI_Ext
    INC     Wave                ; vague détruite : la suivante, plus bas
    JSR     New_Wave
    RTS
UI_Ext:
    JSR     Extents
    LDA     Dir
    BMI     UI_Left
    LDA     MaxCol
    CMPA    #F_W-2
    BLO     UI_March
    BRA     UI_Desc
UI_Left:
    LDA     MinCol
    CMPA    #1
    BHI     UI_March
UI_Desc:
    LDA     #1
    STA     Descending
UI_March:
    JSR     Snd_March
UI_End:
    RTS

; B = rangée d'envahisseurs : Z = 0 s'il en reste un vivant. Préserve B.
Row_Alive:
    PSHS    B
    LDA     #INV_COLS
    MUL
    LDX     #Alive
    ABX
    LDB     #INV_COLS
RA_Loop:
    TST     ,X+
    BNE     RA_Yes
    DECB
    BNE     RA_Loop
    PULS    B
    ORCC    #%00000100          ; Z = 1 : aucun
    RTS
RA_Yes:
    PULS    B
    ANDCC   #%11111011          ; Z = 0
    RTS

; B = rangée d'envahisseurs arrivée sur les boucliers : chaque envahisseur
; vivant efface les cases de bouclier sous lui. Préserve B.
Crush_Shields:
    PSHS    B
    STB     HitInv              ; rangée
    CLR     TmpI                ; colonne d'envahisseur
CS_Loop:
    LDA     #INV_COLS
    LDB     HitInv
    MUL
    ADDB    TmpI
    LDX     #Alive
    ABX
    TST     ,X
    BEQ     CS_Next
    LDB     HitInv
    LDX     #RowX
    LDA     TmpI
    ASLA
    ASLA
    ADDA    B,X                 ; A = colonne de la moitié gauche
    STA     HitCol
    BSR     CS_Cell
    LDA     HitCol
    INCA
    BSR     CS_Cell
CS_Next:
    INC     TmpI
    LDA     TmpI
    CMPA    #INV_COLS
    BLO     CS_Loop
    PULS    B,PC
; A = colonne : la case de bouclier qui s'y trouve est détruite.
CS_Cell:
    STA     TmpC
    CLRB
CSC_Loop:
    LDX     #ShieldX
    LDA     TmpC
    SUBA    B,X
    BCS     CSC_Next
    CMPA    #SHIELD_W
    BHS     CSC_Next
    PSHS    A
    TFR     B,A
    ASLA
    ASLA
    ADDA    ,S+
    LDX     #Shield
    CLR     A,X
    RTS
CSC_Next:
    INCB
    CMPB    #SHIELD_N
    BLO     CSC_Loop
    RTS

; Colonnes extrêmes des envahisseurs vivants : MinCol, MaxCol.
Extents:
    LDA     #$FF
    STA     MinCol
    CLR     MaxCol
    CLR     TmpI                ; rangée
EX_Row:
    CLR     TmpC                ; colonne d'envahisseur
EX_Col:
    LDA     #INV_COLS
    LDB     TmpI
    MUL
    ADDB    TmpC
    LDX     #Alive
    ABX
    TST     ,X
    BEQ     EX_Next
    LDB     TmpI
    LDX     #RowX
    LDA     TmpC
    ASLA
    ASLA
    ADDA    B,X                 ; A = colonne de la moitié gauche
    CMPA    MinCol
    BHS     EX_Max
    STA     MinCol
EX_Max:
    INCA                        ; moitié droite
    CMPA    MaxCol
    BLS     EX_Next
    STA     MaxCol
EX_Next:
    INC     TmpC
    LDA     TmpC
    CMPA    #INV_COLS
    BLO     EX_Col
    INC     TmpI
    LDA     TmpI
    CMPA    #INV_ROWS
    BLO     EX_Row
    RTS

; --- Tirs ennemis : un envahisseur du bas d'une colonne au hasard ---
Upd_EBullets:
    DEC     EFireTimer
    BNE     UE_Move
    JSR     Rand
    ANDA    #31
    ADDA    #20
    STA     EFireTimer
    LDX     #EBActive           ; une place libre ?
    CLRB
UE_Free:
    TST     B,X
    BEQ     UE_Got
    INCB
    CMPB    #EB_N
    BLO     UE_Free
    BRA     UE_Move
UE_Got:
    STB     TmpI                ; place
    JSR     Rand                ; colonne au hasard : A mod 11
UE_Mod:
    CMPA    #INV_COLS
    BLO     UE_Col
    SUBA    #INV_COLS
    BRA     UE_Mod
UE_Col:
    STA     TmpC
    LDB     #INV_ROWS-1         ; l'envahisseur vivant le plus bas
UE_Find:
    PSHS    B
    LDA     #INV_COLS
    MUL
    ADDB    TmpC
    LDX     #Alive
    ABX
    PULS    B
    TST     ,X
    BNE     UE_Shoot
    DECB
    BPL     UE_Find
    BRA     UE_Move             ; colonne vide
UE_Shoot:
    LDX     #RowX
    LDA     TmpC
    ASLA
    ASLA
    ADDA    B,X
    LDX     #RowY
    LDB     B,X
    INCB                        ; juste dessous
    PSHS    B
    LDB     TmpI
    LDX     #EBX
    STA     B,X
    PULS    A
    LDX     #EBY
    STA     B,X
    LDX     #EBActive
    LDA     #1
    STA     B,X
    LDX     #EBY
    LDB     B,X
    JSR     Mark_Row
UE_Move:
    LDA     Frame               ; une rangée toutes les deux trames
    BITA    #1
    BEQ     UE_End
    CLRB
UE_Loop:
    STB     TmpI
    LDX     #EBActive
    TST     B,X
    BEQ     UE_Next
    LDX     #EBY
    LDB     B,X
    JSR     Mark_Row
    LDB     TmpI
    LDX     #EBY
    INC     B,X
    LDA     B,X
    CMPA    #F_H
    BHS     UE_Off              ; sorti par le bas
    TFR     A,B
    JSR     Mark_Row
    LDB     TmpI
    LDX     #EBY
    LDA     B,X
    CMPA    #CAN_Y              ; le canon ?
    BNE     UE_Shield
    LDX     #EBX
    LDA     B,X
    SUBA    CanX
    BCS     UE_Shield
    CMPA    #CAN_W
    BHS     UE_Shield
    JSR     Player_Hit
    RTS
UE_Shield:
    LDA     #1                  ; le tir descend : bouclier rongé par le haut
    STA     HitFromAbove
    LDB     TmpI
    LDX     #EBX
    LDA     B,X
    LDX     #EBY
    LDB     B,X
    JSR     Shield_Hit
    BCC     UE_Next
UE_Off:
    LDB     TmpI
    LDX     #EBActive
    CLR     B,X
UE_Next:
    LDB     TmpI
    INCB
    CMPB    #EB_N
    BLO     UE_Loop
UE_End:
    RTS

; Canon touché : une vie de moins, explosion, pause.
Player_Hit:
    DEC     Lives
    LDA     #ST_DEAD
    STA     State
    LDA     #90
    STA     DeadTimer
    CLRB                        ; tous les tirs disparaissent
PH_Clear:
    LDX     #EBActive
    TST     B,X
    BEQ     PH_Next
    CLR     B,X
    PSHS    B
    LDX     #EBY
    LDB     B,X
    JSR     Mark_Row
    PULS    B
PH_Next:
    INCB
    CMPB    #EB_N
    BLO     PH_Clear
    TST     PBActive
    BEQ     PH_Expl
    CLR     PBActive
    LDB     PBY
    JSR     Mark_Row
PH_Expl:
    LDA     CanX
    LDB     #CAN_Y
    JSR     Add_Explosion
    LDB     #STATUS_Y
    JSR     Mark_Row
    LDX     #Sd_Dead
    JSR     Snd_Play
    RTS

; --- Explosions ---
; A = colonne, B = rangée.
Add_Explosion:
    PSHS    A,B
    LDX     #ExTimer
    CLRB
AE_Free:
    TST     B,X
    BEQ     AE_Got
    INCB
    CMPB    #EX_N
    BLO     AE_Free
    CLRB                        ; toutes prises : on réutilise la première
AE_Got:
    LDA     #12
    STA     B,X
    LDX     #ExX
    LDA     ,S
    STA     B,X
    LDX     #ExY
    LDA     1,S
    STA     B,X
    PULS    A,B
    JSR     Mark_Row
    RTS

Upd_Explosions:
    CLRB
UX_Loop:
    LDX     #ExTimer
    TST     B,X
    BEQ     UX_Next
    DEC     B,X
    BNE     UX_Next
    PSHS    B                   ; terminée : sa rangée est à redessiner
    LDX     #ExY
    LDB     B,X
    JSR     Mark_Row
    PULS    B
UX_Next:
    INCB
    CMPB    #EX_N
    BLO     UX_Loop
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
; X = partition. Un son d'effet bloque la marche pendant quelques trames.
Snd_Play:
    JSR     [VIS_TABLE+vis_Sound]
    LDA     #15
    STA     SndBusy
    RTS

; Une note de la marche des envahisseurs, à chaque pas.
Snd_March:
    TST     SndBusy
    BNE     SM_End
    LDB     MarchIdx
    ASLB
    LDX     #MarchTbl
    ABX
    LDX     ,X
    JSR     [VIS_TABLE+vis_Sound]
    LDA     MarchIdx
    INCA
    ANDA    #3
    STA     MarchIdx
SM_End:
    RTS

; -------------------------------------------------------------------
; Rendu
; -------------------------------------------------------------------
; B = rangée du terrain : à redessiner. Préserve B.
Mark_Row:
    CMPB    #F_H
    BHS     MR_End
    PSHS    A,X
    LDX     #Dirty
    LDA     #1
    STA     B,X
    PULS    A,X
MR_End:
    RTS

Mark_All:
    LDX     #Dirty
    LDB     #F_H
    LDA     #1
MA_Loop:
    STA     ,X+
    DECB
    BNE     MA_Loop
    RTS

; Disp = ce que vis_Window vient de dessiner (intérieur), file vide.
Init_Display:
    LDA     #BLANK_C
    STA     FillTmp
    LDX     #DispC
    LDY     #FillTmp
    LDW     #F_SIZE
    TFM     Y,X+
    LDA     #BLANK_A
    STA     FillTmp
    LDX     #DispA
    LDY     #FillTmp
    LDW     #F_SIZE
    TFM     Y,X+
    CLR     QHead
    CLR     QCount
    RTS

; Recompose les rangées marquées et met les cases changées en file.
; Appelé seulement quand la file est vide.
Compose:
    CLR     QHead
    CLR     QCount
    CLRB
CO_Loop:
    LDX     #Dirty
    TST     B,X
    BEQ     CO_Next
    LDA     QCount              ; place pour une rangée entière ?
    CMPA    #QCAP-F_W
    BHI     CO_End              ; non : la suite à la prochaine vidange
    CLR     B,X
    STB     CurFR
    PSHS    B
    JSR     Compose_Row
    PULS    B
CO_Next:
    INCB
    CMPB    #F_H
    BLO     CO_Loop
CO_End:
    RTS

; Rangée CurFR : Want vidé, objets dessinés, comparé à Disp.
Compose_Row:
    LDA     #F_W
    LDB     CurFR
    MUL
    STD     RowOff
    ADDD    #WantC
    STD     WRowC
    LDD     RowOff
    ADDD    #WantA
    STD     WRowA
    LDX     WRowC
    LDA     #BLANK_C
    LDB     #F_W
CR_ClrC:
    STA     ,X+
    DECB
    BNE     CR_ClrC
    LDX     WRowA
    LDA     #BLANK_A
    LDB     #F_W
CR_ClrA:
    STA     ,X+
    DECB
    BNE     CR_ClrA
    LDA     CurFR
    CMPA    #STATUS_Y
    BNE     CR_Objs
    JSR     Draw_Status
CR_Objs:
    JSR     Draw_Ufo
    JSR     Draw_Envahis
    JSR     Draw_Shields
    JSR     Draw_Cannon
    JSR     Draw_Bullets
    JSR     Draw_Explosions
    JSR     Draw_Msg
    JSR     Diff_Row
    RTS

; A = caractère, B = colonne : case de la rangée en cours, attribut CurAttr.
; Hors du terrain : ignorée. Détruit A, X ; préserve B.
Put:
    CMPB    #F_W
    BHS     PT_End
    LDX     WRowC
    STA     B,X
    LDA     CurAttr
    LDX     WRowA
    STA     B,X
PT_End:
    RTS

; X = texte (0 final), B = colonne de départ, attribut CurAttr.
Put_Str:
    LDA     ,X+
    BEQ     PS_End
    PSHS    X
    JSR     Put
    PULS    X
    INCB
    BRA     Put_Str
PS_End:
    RTS

Draw_Status:
    LDA     #COLOR_TEXT
    STA     CurAttr
    LDU     #Line
    LDX     #TxtScore
    JSR     Append
    LDD     Score
    JSR     Dec16
    CLR     ,U
    LDX     #Line
    LDB     #2
    JSR     Put_Str
    LDU     #Line
    LDX     #TxtRecord
    JSR     Append
    LDD     HiScore
    JSR     Dec16
    CLR     ,U
    LDX     #Line
    LDB     #22
    JSR     Put_Str
    LDU     #Line
    LDX     #TxtVies
    JSR     Append
    LDA     Lives
    ADDA    #ASCII_0
    STA     ,U+
    CLR     ,U
    LDX     #Line
    LDB     #F_W-9
    JSR     Put_Str
    RTS

Draw_Ufo:
    LDA     CurFR
    CMPA    #UFO_Y
    BNE     DU_End
    TST     UfoActive
    BEQ     DU_Pts
    LDA     #ATTR_UFO
    STA     CurAttr
    LDB     UfoX
    LDA     #CHR_UFO
    JSR     Put
    INCB
    LDA     #CHR_UFO+1
    JSR     Put
    INCB
    LDA     #CHR_UFO+2
    JSR     Put
DU_Pts:
    TST     UfoPtsTimer         ; bonus gagné, à la place de la soucoupe
    BEQ     DU_End
    LDA     #COLOR_TEXT
    STA     CurAttr
    LDU     #Line
    LDD     UfoPts
    JSR     Dec16
    CLR     ,U
    LDX     #Line
    LDB     UfoPtsX
    JSR     Put_Str
DU_End:
    RTS

Draw_Envahis:
    CLR     TmpI                ; rangée d'envahisseurs
DI_Row:
    LDB     TmpI
    LDX     #RowY
    LDA     B,X
    CMPA    CurFR
    BNE     DI_NextRow
    LDX     #RowAttr
    LDA     B,X
    STA     CurAttr
    LDX     #RowFrame           ; glyphe : type de la rangée + position * 2
    LDA     B,X
    ASLA
    LDX     #RowGlyph
    ADDA    B,X
    STA     TmpA
    CLR     TmpC
DI_Col:
    LDA     #INV_COLS
    LDB     TmpI
    MUL
    ADDB    TmpC
    LDX     #Alive
    ABX
    TST     ,X
    BEQ     DI_NextCol
    LDB     TmpI
    LDX     #RowX
    LDA     TmpC
    ASLA
    ASLA
    ADDA    B,X
    TFR     A,B
    LDA     TmpA
    JSR     Put
    INCB
    LDA     TmpA
    INCA
    JSR     Put
DI_NextCol:
    INC     TmpC
    LDA     TmpC
    CMPA    #INV_COLS
    BLO     DI_Col
DI_NextRow:
    INC     TmpI
    LDA     TmpI
    CMPA    #INV_ROWS
    BLO     DI_Row
    RTS

Draw_Shields:
    LDA     CurFR
    CMPA    #SHIELD_Y
    BNE     DS_End
    LDA     #ATTR_SHIELD
    STA     CurAttr
    CLR     TmpI                ; case 0..15
DS_Loop:
    LDB     TmpI
    LDX     #Shield
    LDA     B,X                 ; points de vie 0..3
    BEQ     DS_Next
    LDX     #ShieldChr
    LDA     A,X
    PSHS    A
    LDA     TmpI                ; colonne = ShieldX[case/4] + case mod 4
    LSRA
    LSRA
    LDX     #ShieldX
    LDB     A,X
    LDA     TmpI
    ANDA    #3
    PSHS    A
    ADDB    ,S+
    PULS    A
    JSR     Put
DS_Next:
    INC     TmpI
    LDA     TmpI
    CMPA    #SHIELD_N*SHIELD_W
    BLO     DS_Loop
DS_End:
    RTS

Draw_Cannon:
    LDA     CurFR
    CMPA    #CAN_Y
    BNE     DC_End
    LDA     State
    CMPA    #ST_DEAD            ; détruit : seule l'explosion se voit
    BEQ     DC_End
    LDA     #ATTR_CAN
    STA     CurAttr
    LDB     CanX
    LDA     #CHR_CAN_L
    JSR     Put
    INCB
    LDA     #CHR_CAN_M
    JSR     Put
    INCB
    LDA     #CHR_CAN_R
    JSR     Put
DC_End:
    RTS

Draw_Bullets:
    TST     PBActive
    BEQ     DB_Enemy
    LDA     PBY
    CMPA    CurFR
    BNE     DB_Enemy
    LDA     #ATTR_PBUL
    STA     CurAttr
    LDB     PBX
    LDA     #CHR_PBUL
    JSR     Put
DB_Enemy:
    LDA     #ATTR_EBUL
    STA     CurAttr
    CLR     TmpI
DB_Loop:
    LDB     TmpI
    LDX     #EBActive
    TST     B,X
    BEQ     DB_Next
    LDX     #EBY
    LDA     B,X
    CMPA    CurFR
    BNE     DB_Next
    LDX     #EBX
    LDB     B,X
    BITA    #1                  ; il ondule en descendant
    BNE     DB_Odd
    LDA     #CHR_EBUL
    BRA     DB_Put
DB_Odd:
    LDA     #CHR_EBUL2
DB_Put:
    JSR     Put
DB_Next:
    INC     TmpI
    LDA     TmpI
    CMPA    #EB_N
    BLO     DB_Loop
    RTS

Draw_Explosions:
    LDA     #ATTR_EXPL
    STA     CurAttr
    CLR     TmpI
DX_Loop:
    LDB     TmpI
    LDX     #ExTimer
    TST     B,X
    BEQ     DX_Next
    LDX     #ExY
    LDA     B,X
    CMPA    CurFR
    BNE     DX_Next
    LDX     #ExX
    LDB     B,X
    LDA     #CHR_EXPL
    JSR     Put
    INCB
    LDA     #CHR_EXPL+1
    JSR     Put
DX_Next:
    INC     TmpI
    LDA     TmpI
    CMPA    #EX_N
    BLO     DX_Loop
    RTS

Draw_Msg:
    LDA     State
    CMPA    #ST_OVER
    BNE     DM_End
    LDA     #COLOR_TEXT
    STA     CurAttr
    LDA     CurFR
    CMPA    #MSG_Y
    BNE     DM_2
    LDX     #TxtOver
    LDB     #(F_W-9)/2
    JSR     Put_Str
    RTS
DM_2:
    CMPA    #MSG_Y+2
    BNE     DM_3
    LDX     #TxtRejouer
    LDB     #(F_W-34)/2
    JSR     Put_Str
    RTS
DM_3:
    CMPA    #MSG_Y+4
    BNE     DM_End
    TST     NewRecord
    BEQ     DM_End
    LDX     #TxtNouveau
    LDB     #(F_W-16)/2
    JSR     Put_Str
DM_End:
    RTS

; Compare la rangée CurFR de Want à Disp ; met chaque case différente
; en file (adresse VRAM, caractère, attribut) et met Disp à jour.
Diff_Row:
    LDD     RowOff
    ADDD    #DispC
    STD     DRowC
    LDD     RowOff
    ADDD    #DispA
    STD     DRowA
    LDA     #80                 ; adresse VRAM du début de la rangée
    LDB     CurFR
    ADDB    #F_Y
    MUL
    ADDD    #VRAM_BASE+F_X
    STD     VRow
    CLRB                        ; colonne
DF_Loop:
    LDX     WRowC
    LDA     B,X
    LDX     DRowC
    CMPA    B,X
    BNE     DF_Chg
    LDX     WRowA
    LDA     B,X
    LDX     DRowA
    CMPA    B,X
    BEQ     DF_Next
DF_Chg:
    LDX     WRowC
    LDA     B,X
    LDX     DRowC
    STA     B,X
    STA     TmpC
    LDX     WRowA
    LDA     B,X
    LDX     DRowA
    STA     B,X
    STA     TmpA
    PSHS    B
    LDB     QCount              ; QChr / QAttr[QCount] (ABX : non signé)
    LDX     #QChr
    ABX
    LDA     TmpC
    STA     ,X
    LDB     QCount
    LDX     #QAttr
    ABX
    LDA     TmpA
    STA     ,X
    LDB     QCount              ; QAddr[QCount] = VRow + colonne
    CLRA
    LSLD
    ADDD    #QAddr
    TFR     D,X
    LDB     ,S
    CLRA
    ADDD    VRow
    STD     ,X
    INC     QCount
    PULS    B
DF_Next:
    INCB
    CMPB    #F_W
    BLO     DF_Loop
    RTS

; Ecrit au plus APPLY_MAX cases de la file, juste après le VSYNC,
; caractères puis attributs, IRQ masquées.
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

; Append / Dec16 : source unique lib/str.asm (U = pointeur d'écriture)
    include "../lib/str.asm"

; -------------------------------------------------------------------
; Données
; -------------------------------------------------------------------
TxtTitre:       FCN " ENVAHIS "
TxtVisVieux:    FCN "OSM-VISION trop ancien pour ENVAHIS."
TxtScore:       FCN "SCORE "
TxtVies:        FCN "VIES "
TxtRecord:      FCN "RECORD "
TxtNouveau:     FCN "NOUVEAU RECORD !"
HiName:         FCC "ENVAHIS.HI    "   ; 15 caractères, complété par des espaces
TxtOver:        FCN "GAME OVER"
TxtRejouer:     FCN "Espace : rejouer   Echap : quitter"

RowAttr:        FCB $8B,$8D,$8D,$8E,$8E ; cyan, magenta, magenta, jaune (vifs ; vert = boucliers)
RowGlyph:       FCB CHR_CALMAR,CHR_CRABE,CHR_CRABE,CHR_POULPE,CHR_POULPE
RowPts:         FCB 30,20,20,10,10
ShieldX:        FCB 7,20,33,46          ; colonne de chaque bouclier
; Boucliers : état d'une case 0 (vide) .. 5 ; glyphe et état suivant
; selon le sens du tir (par le haut : tir ennemi ; par le bas : le tien)
SH_PLEIN        equ 1
ShieldChr:      FCB 0,CHR_SH_PLEIN,CHR_SH_HAUT,CHR_SH_BAS,CHR_SH_TROUE,CHR_SH_RUINE
NextAbove:      FCB 0,2,4,4,5,0     ; plein -> rongé haut -> troué -> ruiné -> vide
NextBelow:      FCB 0,3,4,4,5,0     ; plein -> rongé bas  -> troué -> ruiné -> vide
UfoBonus:       FDB 50,100,150,300

; Partitions : FDB voix1,voix2 / FCB durée ; fin FDB SN_END (lib/snd.inc)
Sd_Shot:
    FDB     SN_C6,SN_SIL
    FCB     1
    FDB     SN_G5,SN_SIL
    FCB     1
    FDB     SN_END
Sd_Kill:
    FDB     SN_E4,SN_SIL
    FCB     2
    FDB     SN_C4,SN_SIL
    FCB     2
    FDB     SN_G3,SN_SIL
    FCB     3
    FDB     SN_END
Sd_Dead:
    FDB     SN_G4,SN_C4
    FCB     6
    FDB     SN_E4,SN_A3
    FCB     6
    FDB     SN_C4,SN_F3
    FCB     6
    FDB     SN_G3,SN_C3
    FCB     12
    FDB     SN_END
Sd_Over:
    FDB     SN_C4,SN_SIL
    FCB     10
    FDB     SN_G3,SN_SIL
    FCB     10
    FDB     SN_E3,SN_SIL
    FCB     10
    FDB     SN_C3,SN_SIL
    FCB     20
    FDB     SN_END
Sd_M1:
    FDB     SN_A3,SN_SIL
    FCB     3
    FDB     SN_END
Sd_M2:
    FDB     SN_G3,SN_SIL
    FCB     3
    FDB     SN_END
Sd_M3:
    FDB     SN_F3,SN_SIL
    FCB     3
    FDB     SN_END
Sd_M4:
    FDB     SN_E3,SN_SIL
    FCB     3
    FDB     SN_END
MarchTbl:       FDB Sd_M1,Sd_M2,Sd_M3,Sd_M4
Sd_UfoIn:
    FDB     SN_E6,SN_SIL
    FCB     2
    FDB     SN_B5,SN_SIL
    FCB     2
    FDB     SN_E6,SN_SIL
    FCB     2
    FDB     SN_END
Sd_UfoHit:
    FDB     SN_C5,SN_SIL
    FCB     3
    FDB     SN_E5,SN_SIL
    FCB     3
    FDB     SN_G5,SN_SIL
    FCB     3
    FDB     SN_C6,SN_SIL
    FCB     6
    FDB     SN_END

; --- Variables ---
Seed            rmb 1
LastTick        rmb 2
KeyLeft         rmb 1           ; non nul : flèche gauche enfoncée
KeyRight        rmb 1
KbE0            rmb 1           ; préfixe E0 reçu
KbRel           rmb 1           ; préfixe F0 reçu
FireReq         rmb 1
QuitReq         rmb 1
EscUp           rmb 1
State           rmb 1
Frame           rmb 1
DeadTimer       rmb 1
Score           rmb 2
HiScore         rmb 2           ; meilleur score (ENVAHIS.HI)
NewRecord       rmb 1           ; <>0 : record battu dans cette partie
Lives           rmb 1
Wave            rmb 1           ; vagues détruites (difficulté)
UfoActive       rmb 1
UfoX            rmb 1
UfoDir          rmb 1           ; +1 / -1
UfoTimer        rmb 2           ; trames avant la prochaine soucoupe
UfoPts          rmb 2           ; bonus gagné
UfoPtsX         rmb 1
UfoPtsTimer     rmb 1           ; trames d'affichage du bonus
HitFromAbove    rmb 1           ; sens du tir pour Shield_Hit
Alive           rmb INV_N
AliveCount      rmb 1
RowX            rmb INV_ROWS
RowY            rmb INV_ROWS
RowFrame        rmb INV_ROWS        ; position d'animation 0/1 de chaque rangée
Dir             rmb 1           ; +1 droite, -1 gauche
Descending      rmb 1           ; <>0 : ce pas descend au lieu d'avancer
CurRow          rmb 1           ; rangée qui bouge au prochain tic
MoveTimer       rmb 1
MinCol          rmb 1
MaxCol          rmb 1
CanX            rmb 1
PBActive        rmb 1
PBX             rmb 1
PBY             rmb 1
EBActive        rmb EB_N
EBX             rmb EB_N
EBY             rmb EB_N
EFireTimer      rmb 1
ExTimer         rmb EX_N
ExX             rmb EX_N
ExY             rmb EX_N
Shield          rmb SHIELD_N*SHIELD_W
SndBusy         rmb 1
MarchIdx        rmb 1
HitCol          rmb 1
HitRow          rmb 1
HitInv          rmb 1
TmpI            rmb 1
TmpC            rmb 1
TmpA            rmb 1
NumStarted      rmb 1           ; lib/str.asm (Dec16)
DigitCnt        rmb 1           ; lib/str.asm (Dec16)
Line            rmb 40
CurFR           rmb 1           ; rangée en cours de composition
CurAttr         rmb 1
RowOff          rmb 2
WRowC           rmb 2
WRowA           rmb 2
DRowC           rmb 2
DRowA           rmb 2
VRow            rmb 2
FillTmp         rmb 1
Dirty           rmb F_H
QHead           rmb 1
QCount          rmb 1
ApN             rmb 1
QAddr           rmb QCAP*2
QChr            rmb QCAP
QAttr           rmb QCAP
WantC           rmb F_SIZE
WantA           rmb F_SIZE
DispC           rmb F_SIZE
DispA           rmb F_SIZE

; Les services d'affichage (lib/vis.inc) : l'application tourne dans sa
; propre page et emporte sa copie (OSM-VISION, en page 0, ne se voit pas).
    include "../lib/vision.asm"
