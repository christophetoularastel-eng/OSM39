; ===================================================================
; OSMVISION.ASM - Système d'Exploitation Visuel pour OSM39 V2
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

    export Vision_Start

; --- Constantes UI : source unique dans lib/ui.inc (partagee avec BRIQUES) ---
    include "../lib/ui.inc"
; --- Services exposes aux applications fenetrees : contrat dans lib/vis.inc ---
    include "../lib/vis.inc"

ICO_FILE_L      equ $82
ICO_FILE_R      equ $83
ICO_DIR_L       equ $80             ; dossier (onglet + boîte)
ICO_DIR_R       equ $81
REC             equ 16              ; un fichier de la liste : nom (15) + drapeaux (1)
FL_DIR          equ $01             ; dossier
FL_PARENT       equ $02             ; l'entrée ".." (dossier parent)

; --- Défilement de la liste ---
MAX_FILES       equ 64          ; fichiers gardés en mémoire (240 maximum : indices sur 8 bits)
VISIBLE_ROWS    equ 16          ; lignes de la liste visibles dans la fenêtre
ASCII_0         equ $30
MENU_X          equ 26          ; colonne du menu contextuel
MENU_W          equ 22          ; largeur (bordures comprises)
MENU_ITEMS      equ 12          ; Ouvrir Editer Voir Renommer Copier Couper Coller Nouveau-dossier Executer Infos Supprimer Terminal
MENU_H          equ MENU_ITEMS+2
MENU_Y_MAX      equ 24-MENU_H   ; ligne max du haut du menu (ombre comprise, il tient à l'écran)
PATH_NIV        equ 8           ; niveaux de dossiers d'un chemin reconstruit (Coller)
; --- Applications fenêtrées (attribut 'a' = bit 4, ex. CHMOD BRIQUES +x+a) ---
ATTR_APP        equ $10
; Notes, SND_PTR/SND_TIMER et format de partition : source unique dans
; lib/snd.inc (partagee avec BRIQUES ; hardware.inc est inclus plus haut).
    include "../lib/snd.inc"
SORT_ENABLED    equ 1           ; 0 = désactive le tri (pour isoler un problème)
MAX_ARGV        equ 9           ; arguments max (argv = 20 octets : 10 mots dont le 0 final)
REN_MAX         equ 12          ; longueur max d'un nom de fichier (8.3)
CMD_MAX         equ 55          ; longueur max d'une ligne de commande
; --- Visualiseur (Voir) ---
SCRATCH_PAGE    equ 3           ; page tampon pour charger le fichier (libre dans OSM-VISION)
VIEW_X          equ 2           ; fenêtre 76 x 23 en (2,1)
VIEW_Y          equ 1
VIEW_W          equ 76
VIEW_H          equ 23
VIEW_TX         equ 3           ; zone de texte : colonne 3, ligne 3
VIEW_TY         equ 3
VIEW_COLS       equ 72
VIEW_ROWS       equ 19
VIEW_STATUS_ROW equ 22
MAX_LINES       equ 1024        ; lignes indexées en mode texte
ASCII_SPACE     equ $20         ; espace en page 0 (le code $00 y affiche un (c))
ARROW_UP        equ $42         ; flèche haut  (page 1 du générateur : attribut bit 7 = 1)
ARROW_DN        equ $43         ; flèche bas   (idem)
UPMARK_POS      equ VRAM_BASE+(7*80+47)*VRAM_PAS     ; première ligne de la liste, colonne de droite
DNMARK_POS      equ VRAM_BASE+(23*80+47)*VRAM_PAS    ; bas de la fenêtre, colonne de droite
STATUS_POS      equ VRAM_BASE+(23*80+12)*VRAM_PAS    ; "sel/total" en bas à gauche

    section .code

; ===================================================================
; EN-TETE FIXE : point d'entree, puis table des services (lib/vis.inc).
; Ces adresses sont un CONTRAT avec les applications deja assemblees :
; $0000 BRA (2 octets), $0002 nombre d'entrees, $0003 la table.
; On n'ajoute qu'en fin de table.
; ===================================================================
Vision_Start:
    BRA     Vision_Main
Vision_Main:
    ; 1. Désactiver et garer le curseur à l'offset 1999 ($07CF)
    LDA     #10
    STA     CRTC_RS
    LDA     #$2D            ; Bit 5=1 : Not Displayed
    STA     CRTC_DATA
    LDA     #14             ; R14 : Cursor High Address
    STA     CRTC_RS
    LDA     #$07
    STA     CRTC_DATA
    LDA     #15             ; R15 : Cursor Low Address
    STA     CRTC_RS
    LDA     #$CF            ; Cache le curseur en bas à droite sous l'ombre
    STA     CRTC_DATA

    ; 2. Charger le répertoire
    JSR     Load_Directory
    CLR     BootSnd
    LDA     KeepPos             ; retour d'un programme : retrouver le même fichier
    CMPA    #$A5
    BNE     VS_First
    CLR     KeepPos
    JSR     Restore_ByName
    BRA     VS_NoKeep
VS_First:
    INC     BootSnd             ; premier lancement : jingle de démarrage
VS_NoKeep:

    ; 3. Dessiner l'interface
    JSR     Draw_Base_UI
    JSR     Aide_Si
    JSR     Draw_FileList

    ; Rendre la main à l'affichage

    LDA     BootSnd
    BEQ     Event_Loop
    CLR     BootSnd
    JSR     Snd_Boot

; Clavier sans attente et Clouris à chaque trame. En entrant (après chaque
; action), la file du clavier est vidée si quelqu'un a lu le clavier brut
; (NEW_CODE à 0), comme le fait scan_keyboard : un programme rendu ne
; laisse pas ses touches à OSM-VISION.
Event_Loop:
    TST     NEW_CODE
    BNE     EL_Attente
    LDA     kbd_tete
    STA     kbd_queue
    CLR     kbd_apres_f0
    CLR     e0_received
EL_Attente:
    JSR     [table_function_ram+sys_kbd_poll]
    TSTA
    BNE     EL_Touche
    LDE     #1                  ; une trame ; au retour, l'écran est libre
    JSR     [table_function_ram+sys_video_wait_vsync]
    JSR     Clou_Lit
    BEQ     EL_Pointeur
    LDB     #1                  ; la Clouris sert : le pointeur s'affiche
    STB     PtrVu
    BITA    #CLOU_CLIC
    LBNE    Clou_Clic
    BITA    #CLOU_CENTRE
    LBNE    Clou_Centre
    JSR     Ptr_Bord            ; poussé contre le haut ou le bas de la liste ?
    BCS     EL_Attente          ; elle a défilé
    JSR     Ptr_Trame           ; A = pas : le pointeur se déplace
    JSR     Ptr_Survol          ; la ligne sous le pointeur devient la sélection
    BRA     EL_Attente
EL_Pointeur:
    TST     PtrVu               ; à redessiner après une action ?
    BEQ     EL_Attente
    TST     PtrOn
    BNE     EL_Attente
    JSR     Ptr_Trame           ; A = 0 : posé sans bouger
    BRA     EL_Attente

EL_Touche:
    PSHS    A
    JSR     Ptr_Cache
    PULS    A
    LDB     Selection       ; état avant la touche (pour ne redessiner que le nécessaire)
    STB     OldSel
    LDB     TopIndex
    STB     OldTop

    CMPA    #$1B            ; Echap -> Quitter
    LBEQ    Quit_Vision
    CMPA    #$80            ; Flèche HAUT
    LBEQ    Move_Up
    CMPA    #$81            ; Flèche BAS
    LBEQ    Move_Down
    CMPA    #$82            ; Flèche GAUCHE -> page précédente
    LBEQ    Page_Up
    CMPA    #$83            ; Flèche DROITE -> page suivante
    LBEQ    Page_Down
    CMPA    #KEY_PGUP       ; Page préc. / suiv. (BIOS récent)
    LBEQ    Page_Up
    CMPA    #KEY_PGDN
    LBEQ    Page_Down
    CMPA    #KEY_HOME       ; Début : premier fichier
    LBEQ    Sel_First
    CMPA    #KEY_END        ; Fin : dernier fichier
    LBEQ    Sel_Last
    CMPA    #KEY_DEL        ; Suppr : supprimer (avec confirmation)
    LBEQ    Act_Delete
    CMPA    #$0D            ; Entrée -> Ouvrir (selon l'extension)
    LBEQ    Act_Open
    CMPA    #$09            ; Tab -> exécuter une commande
    LBEQ    Act_Command
    CMPA    #$03            ; Ctrl+C / Ctrl+X / Ctrl+V : copier, couper, coller
    LBEQ    Act_Copy
    CMPA    #$18
    LBEQ    Act_Cut
    CMPA    #$16
    LBEQ    Act_Paste
    CMPA    #$0E            ; Ctrl+N : nouveau dossier
    LBEQ    Act_NewDir
    CMPA    #$20            ; Espace -> menu contextuel
    LBEQ    Menu_Open
    CMPA    #'t'            ; 't' / 'T' : Terminal (le SHELL dans une fenêtre)
    LBEQ    Act_Terminal
    CMPA    #'T'
    LBEQ    Act_Terminal
    CMPA    #'?'            ; '?' : panneau des raccourcis, ouvert / fermé
    LBEQ    Aide_Bascule
    CMPA    #$6D            ; 'm' / 'M' : son oui / non
    LBEQ    Snd_Toggle
    CMPA    #$4D
    LBEQ    Snd_Toggle
    LBRA    Event_Loop

; -------------------------------------------------------------------
; CLOURIS : le pouce clique là où est le pointeur ; le centre ouvre le
; menu (comme Espace). Dans la liste, la ligne survolée devient la
; sélection (Ptr_Survol) et un clic l'ouvre (comme Entrée) ; les flèches
; de défilement (colonne 47, lignes 7 et 23) tournent les pages.
; -------------------------------------------------------------------
Clou_Centre:
    JSR     Ptr_Cache
    LBRA    Menu_Open

Clou_Clic:
    JSR     Ptr_Cache
    LDB     Selection
    STB     OldSel
    LDB     TopIndex
    STB     OldTop
    LDA     PtrX
    LDB     PtrY
    CMPA    #47
    BNE     CC_Liste
    CMPB    #7
    LBEQ    Page_Up
    CMPB    #23
    LBEQ    Page_Down
CC_Liste:
    JSR     Ptr_Ligne           ; sur une ligne de la liste ?
    LBCS    Event_Loop
    CMPB    Selection
    LBEQ    Act_Open
    STB     Selection
    LBRA    Redraw

; -------------------------------------------------------------------
; Le pointeur : la flèche UI_FLECHE (page 1) en jaune sur le fond de la
; case, dont le caractère et l'attribut sont gardés. Il est ôté avant
; toute action (qui peut redessiner) et reposé quand la boucle est
; inactive ; seule cette boucle dessine pendant qu'il est affiché.
; -------------------------------------------------------------------
PTR_MAX_X       equ 79
PTR_MAX_Y       equ 24

; A = pas (CLOU_HAUT...), appelé au début d'une trame : ôte, déplace, pose
Ptr_Trame:
    PSHS    CC,A
    ORCC    #%00010000
    CLR     VRAM_CTRL
    JSR     Ptr_Ote
    LDA     1,S
    BITA    #CLOU_HAUT
    BEQ     PT_PasHaut
    TST     PtrY
    BEQ     PT_PasHaut
    DEC     PtrY
PT_PasHaut:
    BITA    #CLOU_BAS
    BEQ     PT_PasBas
    LDB     PtrY
    CMPB    #PTR_MAX_Y
    BHS     PT_PasBas
    INC     PtrY
PT_PasBas:
    BITA    #CLOU_GAUCHE
    BEQ     PT_PasGauche
    TST     PtrX
    BEQ     PT_PasGauche
    DEC     PtrX
PT_PasGauche:
    BITA    #CLOU_DROITE
    BEQ     PT_PasDroite
    LDB     PtrX
    CMPB    #PTR_MAX_X
    BHS     PT_PasDroite
    INC     PtrX
PT_PasDroite:
    JSR     Ptr_Pose
    PULS    CC,A,PC

; Le pointeur sur une ligne de la liste (colonnes 11-46) : elle devient la
; sélection, recolorée comme au clavier.
Ptr_Survol:
    BSR     Ptr_Ligne
    BCS     PS_Fin
    CMPB    Selection
    BEQ     PS_Fin
    LDA     TopIndex
    BRA     Ptr_Liste
PS_Fin:
    RTS

; A = pas. Le pointeur sur la dernière ligne visible de la liste, poussé
; vers le bas (ou sur la première, vers le haut) : la liste défile d'une
; ligne, comme Bas/Haut au clavier, et le pointeur reste. C = 1 : défilé.
Ptr_Bord:
    PSHS    A
    BSR     Ptr_Ligne
    BCS     PB_Non
    LDA     ,S
    BITA    #CLOU_BAS
    BEQ     PB_Haut
    LDA     PtrY
    CMPA    #7+VISIBLE_ROWS-1
    BNE     PB_Haut
    INCB                        ; le fichier suivant
    CMPB    FileCount
    BHS     PB_Non
    LDA     TopIndex
    INCA
    BRA     PB_Defile
PB_Haut:
    LDA     ,S
    BITA    #CLOU_HAUT
    BEQ     PB_Non
    LDA     PtrY
    CMPA    #7
    BNE     PB_Non
    TSTB                        ; déjà le premier fichier
    BEQ     PB_Non
    DECB
    TFR     B,A
PB_Defile:
    BSR     Ptr_Liste
    PULS    A
    ORCC    #1
    RTS
PB_Non:
    PULS    A
    ANDCC   #$FE
    RTS

; B = nouvelle sélection, A = nouveau TopIndex : la liste redessinée comme
; au clavier (Update_List). Draw_Names et Color_Row repeignent les colonnes
; 12-29 : si la flèche y est, elle est ôtée (reposée à la trame suivante).
Ptr_Liste:
    PSHS    D
    LDA     Selection
    STA     OldSel
    LDA     TopIndex
    STA     OldTop
    LDA     PtrX
    CMPA    #12
    BLO     PLi_Garde
    CMPA    #29
    BHI     PLi_Garde
    JSR     Ptr_Cache
PLi_Garde:
    PULS    D
    STA     TopIndex
    STB     Selection
    JMP     Update_List

; B = indice du fichier sous le pointeur, C = 0 ; C = 1 : aucun
Ptr_Ligne:
    LDA     PtrX
    CMPA    #11
    BLO     PL_Aucun
    CMPA    #46
    BHI     PL_Aucun
    LDB     PtrY
    SUBB    #7
    BLO     PL_Aucun
    CMPB    #VISIBLE_ROWS
    BHS     PL_Aucun
    ADDB    TopIndex
    CMPB    FileCount
    BHS     PL_Aucun
    ANDCC   #$FE
    RTS
PL_Aucun:
    ORCC    #1
    RTS

; Ôte le pointeur s'il est affiché (attend une trame)
Ptr_Cache:
    TST     PtrOn
    BEQ     PC_Fin
    JSR     Sync_Begin
    JSR     Ptr_Ote
    JSR     Sync_End
PC_Fin:
    RTS

; VRAM accessible (IRQ masquées) : remet la case sous le pointeur
Ptr_Ote:
    TST     PtrOn
    BEQ     PO_Fin
    LDA     PtrX
    LDB     PtrY
    JSR     Calc_Addr
    LDD     PtrSous
    STA     ,Y
    STB     VRAM_COL_OFS,Y
    CLR     PtrOn
PO_Fin:
    RTS

; VRAM accessible : garde la case et y pose la flèche
Ptr_Pose:
    LDA     PtrX
    LDB     PtrY
    JSR     Calc_Addr
    LDA     ,Y
    LDB     VRAM_COL_OFS,Y
    STD     PtrSous
    ANDB    #%01110000          ; le fond de la case
    ORB     #$86                ; page 1, flèche jaune
    CMPB    #$E6                ; sur fond jaune : blanche
    BNE     PP_Attr
    LDB     #$E7
PP_Attr:
    STB     VRAM_COL_OFS,Y
    LDA     #UI_FLECHE
    STA     ,Y
    LDA     #1
    STA     PtrOn
    RTS

PtrX            FCB 30
PtrY            FCB 12
PtrOn           FCB 0               ; 1 : la flèche est à l'écran
PtrVu           FCB 0               ; 1 : la Clouris a servi (pointeur affiché)
PtrSous         FDB 0               ; caractère et attribut sous la flèche

; Début / Fin de la liste
Sel_First:
    CLR     Selection
    CLR     TopIndex
    LBRA    Redraw

Sel_Last:
    LDA     FileCount
    LBEQ    Event_Loop
    DECA
    STA     Selection
    SUBA    #VISIBLE_ROWS-1     ; TopIndex = max(0, dernier-15)
    BHS     SL_Top
    CLRA
SL_Top:
    STA     TopIndex
    LBRA    Redraw

; Selection = index absolu dans FileNames (0..FileCount-1)
; TopIndex  = index du premier fichier visible
; Invariant : TopIndex <= Selection <= TopIndex+VISIBLE_ROWS-1

Move_Up:
    LDA     Selection
    LBEQ    Event_Loop
    DECA
    STA     Selection
    CMPA    TopIndex
    BHS     Redraw          ; encore dans la fenêtre visible
    STA     TopIndex        ; sinon la fenêtre remonte d'une ligne
    BRA     Redraw

Move_Down:
    LDA     Selection
    INCA
    CMPA    FileCount
    LBHS    Event_Loop      ; déjà sur le dernier fichier
    STA     Selection
    SUBA    #VISIBLE_ROWS-1 ; A = Selection-15
    BLO     Redraw          ; Selection < 15 : forcément visible
    CMPA    TopIndex
    BLS     Redraw          ; Selection-15 <= Top : encore visible
    STA     TopIndex        ; la sélection devient la dernière ligne visible
    BRA     Redraw

Page_Up:
    LDA     Selection
    SUBA    #VISIBLE_ROWS
    BHS     PgUp_Sel
    CLRA                    ; plafonné à 0
PgUp_Sel:
    STA     Selection
    LDA     TopIndex
    SUBA    #VISIBLE_ROWS
    BHS     PgUp_Top
    CLRA
PgUp_Top:
    STA     TopIndex
    BRA     Redraw

Page_Down:
    LDA     FileCount
    LBEQ    Event_Loop
    LDA     Selection
    ADDA    #VISIBLE_ROWS
    CMPA    FileCount
    BLO     PgDn_Sel        ; Selection+16 existe
    LDA     FileCount
    DECA                    ; sinon : dernier fichier
PgDn_Sel:
    STA     Selection

    LDB     FileCount       ; MaxTop = max(0, FileCount-16)
    SUBB    #VISIBLE_ROWS
    BHS     PgDn_Max
    CLRB
PgDn_Max:
    LDA     TopIndex
    ADDA    #VISIBLE_ROWS
    PSHS    B
    CMPA    ,S+             ; Top+16 <= MaxTop ?
    BLS     PgDn_Top
    TFR     B,A             ; sinon Top = MaxTop
PgDn_Top:
    STA     TopIndex
    ; (continue sur Redraw)

Redraw:
    JSR     Update_List
    LBRA    Event_Loop

; -------------------------------------------------------------------
; Mise à jour partielle de la liste, synchronisée sur le VSYNC.
;  - pas de défilement : seules 2 lignes changent de couleur
;  - défilement        : noms réécrits (TFM) + 2 lignes recolorées
; L'IRQ VSYNC incrémente vsync_tick : en sortie d'attente on est au tout
; début de la fenêtre où le CPU peut écrire dans la VRAM.
; -------------------------------------------------------------------
Update_List:
    LDA     Selection
    CMPA    OldSel
    BNE     UL_Changed
    LDA     TopIndex
    CMPA    OldTop
    BEQ     UL_Nothing          ; rien n'a bougé
UL_Changed:
    JSR     Snd_Tick
    LDE     #1                  ; attendre 1 VSYNC (IRQ démasquées)
    JSR     [table_function_ram+sys_video_wait_vsync]

    PSHS    CC,U
    PSHSW
    ORCC    #%00010000          ; IRQ masquées pendant l'accès VRAM

    LDA     FileCount
    BEQ     UL_End

    LDA     TopIndex
    CMPA    OldTop
    BEQ     UL_Colors           ; pas de défilement : les noms ne changent pas
    BSR     Draw_Names

UL_Colors:
    LDA     OldSel              ; ancienne ligne sélectionnée -> texte normal
    SUBA    OldTop
    LDB     #COLOR_TEXT
    BSR     Color_Row
    LDA     Selection           ; nouvelle ligne -> couleur de sélection
    SUBA    TopIndex
    LDB     #COLOR_SEL
    BSR     Color_Row
    JSR     Draw_Status         ; (trop loin pour un BSR)

UL_End:
    PULSW
    PULS    CC,U
UL_Nothing:
    RTS

; Réécrit les noms visibles (plan caractères) à partir de TopIndex
Draw_Names:

    LDA     FileCount
    SUBA    TopIndex
    CMPA    #VISIBLE_ROWS
    BLS     DN_RowsOk
    LDA     #VISIBLE_ROWS
DN_RowsOk:
    STA     DrawRows

    LDA     TopIndex            ; U = FileNames + TopIndex*REC
    LDB     #REC
    MUL
    ADDD    #FileNames
    TFR     D,U

    CLR     DrawRow
DN_Loop:
    LDB     DrawRow             ; Y = VRAM_BASE + (ligne+7)*80 + 12
    ADDB    #7
    LDA     #VRAM_LIGNE
    MUL
    ADDD    #VRAM_BASE+12*VRAM_PAS
    TFR     D,Y
    LDD     #(ICO_FILE_L*256)+ICO_FILE_R    ; l'icône suit la ligne (dossier ?)
    TST     15,U
    BEQ     DN_Ico
    LDD     #(ICO_DIR_L*256)+ICO_DIR_R
DN_Ico:
    IFNE    CARTE_MONO
    STA     ,Y                  ; mono : les deux cases de l'icône
    STB     VRAM_PAS,Y
    LEAY    3*VRAM_PAS,Y
    LDB     #15                 ; copie les 15 caractères du nom
DN_Car:
    LDA     ,U+
    STA     ,Y++
    DECB
    BNE     DN_Car
    ELSE
    STD     ,Y
    LEAY    3,Y
    LDW     #15
    TFM     U+,Y+               ; copie 15 octets du nom
    ENDC
    LEAU    1,U                 ; les drapeaux
    INC     DrawRow
    LDA     DrawRow
    CMPA    DrawRows
    BLO     DN_Loop
    RTS

; A = ligne dans la fenêtre (0..15), B = attribut
; Colore les 15 cases du nom (plan couleurs)
Color_Row:
    PSHS    B
    TFR     A,B
    ADDB    #7
    LDA     #VRAM_LIGNE
    MUL
    ADDD    #VRAM_COL+15*VRAM_PAS
    TFR     D,Y
    PULS    A
    IFNE    CARTE_MONO
    LDB     #15                         ; mono : une couleur sur deux octets
CR_Case:
    STA     ,Y++
    DECB
    BNE     CR_Case
    ELSE
    LDW     #15
    STA     FillByte
    LDD     #FillByte
    TFM     D,Y+
    LDA     FillByte                    ; sortie identique a l'ancienne boucle : A = octet, B = 0
    CLRB
    ENDC
    RTS

Quit_Vision:
    JSR     Snd_Stop                    ; SHELL va écraser nos partitions : plus de son
    LDA     #$0C
    JSR     [table_function_ram+sys_PrintChar]
    RTS

; ===================================================================
; ROUTINES SECONDAIRES
; ===================================================================


; Services d'affichage (synchronisation, fenêtres, texte, rectangles,
; saisie, boîte de message, sons d'erreur) : source unique lib/vision.asm,
; incluse aussi par chaque application (elle ne voit pas OSM-VISION).
    include "../lib/vision.asm"

; La Clouris (souris tactile sur le port A de l'AY)
    include "../lib/clouris.asm"

; Outils de construction de chaines : source unique dans
; lib/str.asm (Append/Hex8/Dec16 ; U = pointeur d'ecriture ;
; ASCII_0 + NumStarted/DigitCnt de l'application).
    include "../lib/str.asm"

; X = FileNames + Selection*REC (nom du fichier sélectionné)
Sel_Name_Ptr:
    LDA     Selection
    LDB     #REC
    MUL
    LDX     #FileNames
    LEAX    D,X
    RTS

; Redessine toute la fenêtre principale (après une modification du répertoire)
Full_Redraw:
    JSR     Sync_Begin
    LDA     #10
    LDB     #5
    LDW     #$2814
    LDY     #TitleMsg
    JSR     Draw_Window
    JSR     Sync_End
    JSR     Sync_Begin
    JSR     Draw_FileList
    JSR     Sync_End
    RTS

; ===================================================================
; MENU CONTEXTUEL (touche Espace)
; ===================================================================
Menu_Open:
    LDA     FileCount
    LBEQ    Event_Loop
    JSR     Snd_Tick
    CLR     MenuSel
    LDA     Selection
    SUBA    TopIndex
    ADDA    #7+1                ; ligne écran de la sélection, +1
    CMPA    #MENU_Y_MAX
    BLS     MO_Y
    LDA     #MENU_Y_MAX
MO_Y:
    STA     MenuY
    LDA     #MENU_X
    STA     MenuX
    STA     RectX               ; rectangle sauvegardé : ombre comprise
    LDA     MenuY
    STA     RectY
    LDA     #MENU_W+1
    STA     RectW
    LDA     #MENU_H+1
    STA     RectH

    JSR     Sync_Begin
    JSR     Rect_Save
    JSR     Sync_End

    JSR     Sync_Begin
    LDA     MenuX
    LDB     MenuY
    LDW     #(MENU_W*256)+MENU_H
    LDY     #0                  ; pas de titre : fenêtre simple
    JSR     Draw_Window
    JSR     Sync_End

    JSR     Menu_DrawItems

Menu_Loop:                      ; clavier, ou Clouris : haut/bas, pouce = exécuter, centre = fermer
    JSR     [table_function_ram+sys_kbd_poll]
    TSTA
    BNE     ML_Touche
    LDE     #1
    JSR     [table_function_ram+sys_video_wait_vsync]
    JSR     Clou_Lit
    BEQ     ML_Pointeur
    LDB     #1
    STB     PtrVu
    BITA    #CLOU_CLIC
    BNE     ML_Clic
    BITA    #CLOU_CENTRE
    LBNE    Menu_Cancel
    JSR     Ptr_Trame
    JSR     Menu_Survol
    BRA     Menu_Loop
ML_Pointeur:
    TST     PtrVu
    BEQ     Menu_Loop
    TST     PtrOn
    BNE     Menu_Loop
    JSR     Ptr_Trame           ; A = 0 : reposé
    BRA     Menu_Loop
ML_Clic:                        ; le pouce : l'entrée sous la flèche, ou fermer
    JSR     Menu_Ligne
    LBCS    Menu_Cancel
    STB     MenuSel
    BRA     Menu_Run
ML_Touche:
    PSHS    A
    JSR     Ptr_Cache
    PULS    A
    CMPA    #$1B                ; Echap -> fermer
    LBEQ    Menu_Cancel
    CMPA    #$20                ; Espace -> fermer
    LBEQ    Menu_Cancel
    CMPA    #$80
    BEQ     Menu_Up
    CMPA    #$81
    BEQ     Menu_Down
    CMPA    #$0D
    BEQ     Menu_Run
    CMPA    #$61                ; minuscule -> majuscule
    BLO     Menu_Key
    CMPA    #$7A
    BHI     Menu_Key
    ANDA    #$DF
Menu_Key:
    LDX     #MenuKeys
    CLRB
MK_Loop:
    CMPA    ,X+
    BEQ     MK_Found
    INCB
    CMPB    #MENU_ITEMS
    BLO     MK_Loop
    BRA     Menu_Loop
MK_Found:
    STB     MenuSel
    BRA     Menu_Run

Menu_Up:
    LDA     MenuSel
    LBEQ    Menu_Loop
    DEC     MenuSel
    JSR     Snd_Tick
    JSR     Menu_DrawOne                ; A = ancienne entrée (désélectionnée)
    LDA     MenuSel
    JSR     Menu_DrawOne
    LBRA    Menu_Loop
Menu_Down:
    LDA     MenuSel
    INCA
    CMPA    #MENU_ITEMS
    LBHS    Menu_Loop
    STA     MenuSel
    JSR     Snd_Tick
    DECA                                ; A = ancienne entrée
    JSR     Menu_DrawOne
    LDA     MenuSel
    JSR     Menu_DrawOne
    LBRA    Menu_Loop

Menu_Cancel:
    JSR     Snd_Back
    JSR     Menu_Close
    LBRA    Event_Loop

Menu_Run:
    JSR     Menu_Close
    LDA     MenuSel
    LSLA
    LDX     #MenuAction
    JMP     [A,X]               ; les actions reprennent la main dans Event_Loop

Menu_Close:
    JSR     Ptr_Cache           ; la flèche n'est pas dans la sauvegarde
    JSR     Sync_Begin
    JSR     Rect_Restore
    JSR     Sync_End
    RTS

; B = entrée sous la flèche, C = 0 ; C = 1 : hors des entrées
Menu_Ligne:
    LDA     PtrX
    SUBA    MenuX
    BLS     MLi_Aucune
    CMPA    #MENU_W-1
    BHS     MLi_Aucune
    LDB     PtrY
    SUBB    MenuY
    BLS     MLi_Aucune
    CMPB    #MENU_ITEMS
    BHI     MLi_Aucune
    DECB
    ANDCC   #$FE
    RTS
MLi_Aucune:
    ORCC    #1
    RTS

; La flèche sur une entrée : elle devient la sélection du menu (la flèche
; est ôtée : Menu_DrawOne réécrit la ligne ; reposée à la trame suivante)
Menu_Survol:
    BSR     Menu_Ligne
    BCS     MS_Fin
    CMPB    MenuSel
    BEQ     MS_Fin
    PSHS    B
    JSR     Ptr_Cache
    JSR     Snd_Tick
    LDA     MenuSel
    PULS    B
    STB     MenuSel
    JSR     Menu_DrawOne        ; A = ancienne entrée
    LDA     MenuSel
    JSR     Menu_DrawOne
MS_Fin:
    RTS

Menu_DrawItems:                 ; toutes les entrées, chacune dans sa propre trame
    CLR     MenuJ
MDI_Loop:
    LDA     MenuJ
    JSR     Menu_DrawOne
    INC     MenuJ
    LDA     MenuJ
    CMPA    #MENU_ITEMS
    BLO     MDI_Loop
    RTS

; A = indice de l'entrée : une seule ligne, un seul Sync (pas de parasitage)
Menu_DrawOne:
    STA     MenuI
    JSR     Sync_Begin
    LDA     #COLOR_TEXT
    LDB     MenuI
    CMPB    MenuSel
    BNE     MDO_Attr
    LDA     #COLOR_SEL
MDO_Attr:
    STA     TextAttr
    LDA     MenuI
    LSLA
    LDX     #MenuText
    LDX     A,X                 ; X = chaîne de l'entrée
    LDB     MenuY
    ADDB    MenuI
    INCB
    LDA     MenuX
    INCA
    JSR     Put_Text
    JSR     Sync_End
    RTS

MenuText:       FDB Txt_Open,Txt_Edit,Txt_View,Txt_Ren,Txt_Copy,Txt_Cut,Txt_Paste,Txt_NewDir
                FDB Txt_Exec,Txt_Info,Txt_Del,Txt_Term
MenuAction:     FDB Act_Open,Act_Edit,Act_View,Act_Rename,Act_Copy,Act_Cut,Act_Paste,Act_NewDir
                FDB Act_Command,Act_Info,Act_Delete,Act_Terminal
MenuKeys:       FCB $4F,$45,$56,$52,$43,$55,$4C,$4E,$58,$50,$53,$54 ; O E V R C U L N X P S T
Txt_Open:       FCN " Ouvrir         Ent "
Txt_Edit:       FCN " Editer           E "
Txt_View:       FCN " Voir             V "
Txt_Ren:        FCN " Renommer...      R "
Txt_Copy:       FCN " Copier           C "
Txt_Cut:        FCN " Couper           U "
Txt_Paste:      FCN " Coller           L "
Txt_NewDir:     FCN " Nouveau dossier  N "
Txt_Exec:       FCN " Executer...      X "
Txt_Info:       FCN " Proprietes...    P "
Txt_Del:        FCN " Supprimer        S "
Txt_Term:       FCN " Terminal         T "

; ===================================================================
; ACTIONS
; ===================================================================

; ---------------------------------------------------------------- Infos
Act_Info:                       ; "Propriétés" : infos + cases à cocher des attributs
    JSR     Sel_Not_Parent
    LBCS    Event_Loop
    LDA     FileCount
    LBEQ    Event_Loop
    CLR     PropLock
    JSR     Is_Protected                ; fichier système : lecture seule
    BCC     AI_NotProt
    INC     PropLock
AI_NotProt:
    JSR     Sel_Name_Ptr
    JSR     [table_function_ram+sys_FS_FindEntry]   ; remplit g_find_fileInfo
    LBCS    Event_Loop
    LDA     g_find_fileInfo+27
    STA     AttrNew
    STA     AttrOrig
    CLR     AttrCur

    LDA     #12                 ; boîte 40 x 15 en (12,8), ombre : 41 x 16
    STA     RectX
    LDA     #8
    STA     RectY
    LDA     #41
    STA     RectW
    LDA     #16
    STA     RectH
    JSR     Sync_Begin
    JSR     Rect_Save
    JSR     Sync_End

    JSR     Sync_Begin
    LDA     #12
    LDB     #8
    LDW     #(40*256)+15
    LDY     #Txt_PropTitle
    JSR     Draw_Window
    JSR     Sync_End

    JSR     Sync_Begin
    LDA     #COLOR_TEXT
    STA     TextAttr

    LDU     #TmpStr                     ; Nom
    LDX     #Txt_Nom
    JSR     Append
    LDX     #g_find_fileInfo+1
    LDW     #15
    TFM     X+,U+
    CLR     ,U
    LDA     #14
    LDB     #10
    LDX     #TmpStr
    JSR     Put_Text

    LDU     #TmpStr                     ; Taille
    LDX     #Txt_Taille
    JSR     Append
    LDD     g_find_fileInfo+20
    BNE     AI_Big
    LDD     g_find_fileInfo+22
    JSR     Dec16
    LDX     #Txt_Octets
    JSR     Append
    BRA     AI_SizeDone
AI_Big:
    LDX     #Txt_Gros
    JSR     Append
AI_SizeDone:
    CLR     ,U
    LDA     #14
    LDB     #11
    LDX     #TmpStr
    JSR     Put_Text

    LDU     #TmpStr                     ; Chargement : page et adresse
    LDX     #Txt_Charge
    JSR     Append
    LDA     g_find_fileInfo+24
    JSR     Hex8
    LDX     #Txt_Adr
    JSR     Append
    LDA     g_find_fileInfo+25
    JSR     Hex8
    LDA     g_find_fileInfo+26
    JSR     Hex8
    CLR     ,U
    LDA     #14
    LDB     #12
    LDX     #TmpStr
    JSR     Put_Text

    LDA     #14
    LDB     #14
    LDX     #Txt_PropAttr
    JSR     Put_Text
    JSR     Sync_End

    CLR     PropI                       ; les 5 cases à cocher
AI_Rows:
    LDA     PropI
    JSR     Props_DrawRow
    INC     PropI
    LDA     PropI
    CMPA    #5
    BLO     AI_Rows
    LDX     #Txt_PropHint
    LDA     PropLock
    BEQ     AI_Hint
    LDX     #Txt_PropLock
AI_Hint:
    JSR     Props_Hint

Props_Loop:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     Props_Loop
    CMPA    #$1B
    LBEQ    Props_Cancel
    CMPA    #$80
    BEQ     Props_Up
    CMPA    #$81
    BEQ     Props_Down
    CMPA    #$20
    BEQ     Props_Toggle
    CMPA    #$0D
    LBEQ    Props_Apply
    BRA     Props_Loop

Props_Up:
    LDA     AttrCur
    BEQ     Props_Loop
    DEC     AttrCur
    JSR     Snd_Tick
    JSR     Props_DrawRow               ; A = ancienne ligne (désélectionnée)
    LDA     AttrCur
    JSR     Props_DrawRow
    LBRA    Props_Loop

Props_Down:
    LDA     AttrCur
    CMPA    #4
    BHS     Props_Loop
    INC     AttrCur
    JSR     Snd_Tick
    LDA     AttrCur
    DECA
    JSR     Props_DrawRow
    LDA     AttrCur
    JSR     Props_DrawRow
    LBRA    Props_Loop

Props_Toggle:
    LDA     PropLock
    BNE     Props_Loop                  ; protégé : pas de modification
    LDA     AttrCur
    LDB     #3
    MUL
    LDX     #AttrItems
    ABX
    LDA     ,X                          ; masque de la case courante
    EORA    AttrNew
    STA     AttrNew
    JSR     Snd_Tick
    LDA     AttrCur
    JSR     Props_DrawRow
    LBRA    Props_Loop

Props_Apply:
    LDA     PropLock
    BNE     Props_Close
    LDA     AttrNew
    CMPA    AttrOrig
    BEQ     Props_Close                 ; rien changé
    JSR     Sel_Name_Ptr
    LDA     AttrNew
    JSR     [table_function_ram+sys_FS_SetAttributes]
    BCC     PA_Ok
    JSR     Snd_Err
    LDX     #Txt_PropErr                ; échec d'écriture : message, on reste dans la boîte
    JSR     Props_Hint
    LBRA    Props_Loop
PA_Ok:
    JSR     Snd_Ok
    BRA     Props_Close
Props_Cancel:
    JSR     Snd_Back

Props_Close:
    JSR     Sync_Begin
    JSR     Rect_Restore
    JSR     Sync_End
    LBRA    Event_Loop

; X = texte (36 caractères) -> ligne d'aide de la boîte
Props_Hint:
    STX     MsgText
    JSR     Sync_Begin
    LDA     #COLOR_TEXT
    STA     TextAttr
    LDA     #14
    LDB     #21
    LDX     MsgText
    JSR     Put_Text
    JSR     Sync_End
    RTS

; A = numéro de case (0..4) : "[x] Libellé", ligne 15+A, colonne 15
Props_DrawRow:
    STA     PropI
    LDB     #3
    MUL
    LDX     #AttrItems
    ABX
    LDA     ,X
    STA     PropMask
    LDX     1,X                         ; X = libellé
    LDU     #TmpStr
    LDA     #$5B                        ; '['
    STA     ,U+
    LDA     #$20
    LDB     AttrNew
    ANDB    PropMask
    BEQ     PDR_Off
    LDA     #$78                        ; 'x'
PDR_Off:
    STA     ,U+
    LDA     #$5D                        ; ']'
    STA     ,U+
    LDA     #$20
    STA     ,U+
    JSR     Append
PDR_Pad:
    TFR     U,D
    SUBD    #TmpStr
    CMPB    #30
    BHS     PDR_Done
    LDA     #$20
    STA     ,U+
    BRA     PDR_Pad
PDR_Done:
    CLR     ,U
    JSR     Sync_Begin
    LDA     #COLOR_TEXT
    LDB     PropI
    CMPB    AttrCur
    BNE     PDR_Attr
    LDA     #COLOR_SEL
PDR_Attr:
    STA     TextAttr
    LDB     PropI
    ADDB    #15
    LDA     #15
    LDX     #TmpStr
    JSR     Put_Text
    JSR     Sync_End
    RTS

; (masque, libellé) : r w x h a
AttrItems:
    FCB     $04
    FDB     Lbl_R
    FCB     $02
    FDB     Lbl_W
    FCB     $01
    FDB     Lbl_X
    FCB     $08
    FDB     Lbl_H
    FCB     $10
    FDB     Lbl_A
Lbl_R:          FCN "Lecture"
Lbl_W:          FCN "Ecriture"
Lbl_X:          FCN "Executable"
Lbl_H:          FCN "Cache"
Lbl_A:          FCN "Application fenetree"
Txt_PropTitle:  FCN " Proprietes "
Txt_PropAttr:   FCN "Attributs :"
Txt_PropHint:   FCN "Esp:cocher  Entree:OK  Echap:annuler"
Txt_PropLock:   FCN "Fichier protege : lecture seule     "
Txt_PropErr:    FCN "Echec de l'ecriture des attributs   "
Txt_InfoTitle:  FCN " Infos "
Txt_Nom:        FCN "Nom       : "
Txt_Taille:     FCN "Taille    : "
Txt_Octets:     FCN " octets"
Txt_Gros:       FCN "plus de 64 Ko"
Txt_Attr:       FCN "Attributs : "
Txt_Charge:     FCN "Chargement: page "
Txt_Adr:        FCN "  adr $"
Txt_InfoHint:   FCN "Echap : fermer"

; ------------------------------------------------------------ Dossiers
; Entrée dans le dossier sélectionné ("..": le parent), puis nouvelle liste.
Enter_Dir:
    LDY     #DirBuf
    BITA    #FL_PARENT
    BEQ     ED_Nom
    LDD     #$2E2E              ; ".."
    STD     ,Y++
    BRA     ED_Fin
ED_Nom:
    LDB     #15
ED_Car:
    LDA     ,X+
    CMPA    #$20
    BEQ     ED_Fin
    STA     ,Y+
    DECB
    BNE     ED_Car
ED_Fin:
    CLR     ,Y
    LDX     #DirBuf
    JSR     [table_function_ram+sys_FS_ChDir]
    LBCS    Event_Loop
    JSR     Load_Directory
    JSR     Full_Redraw
    LBRA    Event_Loop

; Sel_Not_Dir - C=1 si la sélection est un dossier (ou ".."), C=0 sinon.
Sel_Not_Dir:
    JSR     Sel_Name_Ptr
    LDA     15,X
    BEQ     SND_Fichier
    ORCC    #1
    RTS
SND_Fichier:
    ANDCC   #$FE
    RTS

; Sel_Not_Parent - C=1 si la sélection est "..".
Sel_Not_Parent:
    JSR     Sel_Name_Ptr
    LDA     15,X
    BITA    #FL_PARENT
    BEQ     SND_Fichier
    ORCC    #1
    RTS

; ------------------------------------------------------------ Supprimer
Act_Delete:
    JSR     Sel_Not_Parent
    LBCS    Event_Loop
    JSR     Is_Protected
    BCC     AD_Ok
    LDX     #Txt_Protected
    LDY     #Txt_ProtTitle
    JSR     Msg_Box
    LBRA    Event_Loop
AD_Ok:
    LDA     #13                 ; boîte 34 x 7 en (13,10), ombre : 35 x 8
    STA     RectX
    LDA     #10
    STA     RectY
    LDA     #35
    STA     RectW
    LDA     #8
    STA     RectH
    JSR     Sync_Begin
    JSR     Rect_Save
    JSR     Sync_End

    JSR     Sync_Begin
    LDA     #13
    LDB     #10
    LDW     #(34*256)+7
    LDY     #Txt_DelTitle
    JSR     Draw_Window
    JSR     Sync_End

    JSR     Sync_Begin
    LDA     #COLOR_TEXT
    STA     TextAttr
    LDA     #15
    LDB     #12
    LDX     #Txt_DelAsk
    JSR     Put_Text
    JSR     Sel_Name_Ptr
    LDU     #TmpStr
    LDW     #15
    TFM     X+,U+
    CLR     ,U
    LDA     #15
    LDB     #13
    LDX     #TmpStr
    JSR     Put_Text
    LDA     #15
    LDB     #15
    LDX     #Txt_DelHint
    JSR     Put_Text
    JSR     Sync_End

Del_Wait:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     Del_Wait
    CMPA    #$0D
    BEQ     Del_Do
    CMPA    #$1B
    BNE     Del_Wait
    JSR     Snd_Back
Del_Cancel:
    JSR     Sync_Begin
    JSR     Rect_Restore
    JSR     Sync_End
    LBRA    Event_Loop

Del_Do:
    JSR     Sel_Name_Ptr
    JSR     [table_function_ram+sys_FS_DeleteFile]
    LBCS    Del_Error
    JSR     Snd_Del

    LDA     Selection           ; relire le répertoire en gardant la position
    STA     SaveSel
    LDA     TopIndex
    STA     SaveTop
    JSR     Load_Directory
    JSR     Restore_Index
Del_Draw:
    JSR     Full_Redraw
    LBRA    Event_Loop

Txt_DelTitle:   FCN " Supprimer "
Txt_DelAsk:     FCN "Supprimer definitivement :"
Txt_DelHint:    FCN "Entree : oui     Echap : non"


; ===================================================================
; LANCEMENT DE PROGRAMMES  (même convention que SHELL)
;   input_buffer = ligne de commande, découpée sur place (NUL à la place
;   des espaces) ; argv = mots de 16 bits pointant dans input_buffer,
;   terminé par 0 ; argc = nombre d'arguments ; argv[0] = programme.
; ===================================================================

; Run_Command : lance la ligne contenue dans CmdBuf (terminée par 0)
;   RunPause <> 0 : attend une touche au retour (pour lire la sortie)
Run_Command:
    CLR     AppRan
    ; 1. CmdBuf -> input_buffer
    LDX     #CmdBuf
    LDY     #input_buffer
    LDB     #127
RC_Copy:
    LDA     ,X+
    STA     ,Y+
    BEQ     RC_Copied
    DECB
    BNE     RC_Copy
    CLR     ,Y
RC_Copied:

    ; 2. Découpage en argv / argc (comme Shell.TokenizeLoop, borné)
    LDX     #input_buffer
    LDY     #argv
    CLRB
RC_Tok:
    LDA     ,X
    CMPA    #$20
    BNE     RC_Start
    LEAX    1,X
    BRA     RC_Tok
RC_Start:
    LDA     ,X
    BEQ     RC_TokDone
    CMPB    #MAX_ARGV
    BHS     RC_TokDone
    STX     ,Y++
    INCB
RC_Word:
    LEAX    1,X
    LDA     ,X
    BEQ     RC_TokDone
    CMPA    #$20
    BNE     RC_Word
    CLR     ,X+
    BRA     RC_Tok
RC_TokDone:
    STB     argc
    CLR     ,Y
    CLR     1,Y
    TSTB
    LBEQ    RC_Return           ; ligne vide

    ; 3. Nom du programme : argv[0] en majuscules, complété à 15 par des espaces.
    ;    Il DOIT être en RAM système ($C000+) : LoadandExec change de page mémoire
    ;    avant de relire le nom, un tampon du programme y serait introuvable.
    LDX     argv
    LDY     #FormattedName
    LDB     #15
RC_Fmt:
    LDA     ,X+
    BEQ     RC_Pad
    CMPA    #$61
    BLO     RC_Up
    CMPA    #$7A
    BHI     RC_Up
    SUBA    #$20
RC_Up:
    STA     ,Y+
    DECB
    BNE     RC_Fmt
    BRA     RC_FmtDone
RC_Pad:
    LDA     #$20
RC_PadLoop:
    STA     ,Y+
    DECB
    BNE     RC_PadLoop
RC_FmtDone:

    ; 4. Le programme existe-t-il et est-il exécutable ?
    LDX     #FormattedName
    JSR     [table_function_ram+sys_FS_FindEntry]
    LBCS    RC_NotFound
    LDA     g_find_fileInfo+27
    BITA    #$01
    LBEQ    RC_NotFound
    BITA    #ATTR_APP           ; application fenêtrée : pas de console
    LBNE    RC_App
    LDX     #FormattedName      ; le SHELL (Entrée, Exécuter...) : dans le Terminal
    LDY     #Nom_Shell
    LDB     #15
RC_EstShell:
    LDA     ,X+
    CMPA    ,Y+
    BNE     RC_PasShell
    DECB
    BNE     RC_EstShell
    CLR     RunPause
    JMP     Terminal_Run        ; son RTS rend la main à notre appelant
RC_PasShell:

    ; 5. Un programme console s'ouvre dans une fenêtre (titre : son nom),
    ;    sauf ceux qui dessinent eux-mêmes tout l'écran (PleinEcran : aucun
    ;    aujourd'hui ; VI, le seul, a été retiré le 16 oct. 2026)
    CLR     RunFenetre
    LDX     #PleinEcran
RC_PE:
    TST     ,X
    BEQ     RC_Fenetre
    LDY     #FormattedName
    LDB     #15
RC_PECmp:
    LDA     ,X+
    CMPA    ,Y+
    BNE     RC_PESuiv
    DECB
    BNE     RC_PECmp
    LDA     #$0C                ; plein écran : on efface et on lance
    JSR     [table_function_ram+sys_PrintChar]
    JSR     Curseur_On
    BRA     RC_Echo
RC_PESuiv:
    LEAX    B,X                 ; fin du nom (B >= 1 caractères restants)
    LEAX    -1,X
    BRA     RC_PE
RC_Fenetre:
    LDX     #FormattedName      ; titre " NOM "
    LDY     #RunTitre
    LDA     #$20
    STA     ,Y+
    LDB     #15
RC_Titre:
    LDA     ,X+
    CMPA    #$20
    BEQ     RC_TitreFin
    STA     ,Y+
    DECB
    BNE     RC_Titre
RC_TitreFin:
    LDD     #$2000
    STD     ,Y
    LDY     #RunTitre
    JSR     Term_Ouvre
    LDA     #1
    STA     RunFenetre
RC_Echo:
    LDA     RunPause            ; mode texte : rappelle la commande lancée
    BEQ     RC_NoEcho
    LDX     #CmdBuf
    JSR     [table_function_ram+sys_PrintString]
    JSR     [table_function_ram+sys_PrintCRLF]
RC_NoEcho:
    JSR     Snd_Select                  ; confirmation, puis on attend sa fin : le séquenceur
    JSR     Snd_Wait                    ; lit sa partition à chaque IRQ, dans la page mappée
    LDX     #FormattedName
    LDA     g_find_fileInfo+24
    LDY     g_find_fileInfo+25
    JSR     [table_function_ram+sys_loadandexec]
    BRA     RC_AfterRun

RC_NotFound:
    LDX     #Txt_Unknown
    LDY     #Txt_ErrTitle
    JSR     Msg_Box
    CLR     RunPause
    RTS

RC_AfterRun:
    JSR     Snd_Stop                    ; le programme a pu laisser un son en cours
    LDA     RunPause
    BEQ     RC_Return
    JSR     [table_function_ram+sys_PrintCRLF]
    LDX     #Txt_Pause
    JSR     [table_function_ram+sys_PrintString]
RC_Key:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     RC_Key
RC_Return:
    TST     RunFenetre
    BEQ     RC_Fin
    JSR     Term_Ferme
RC_Fin:
    RTS

; Programmes qui dessinent eux-mêmes tout l'écran : lancés en plein écran
; (noms formatés, 15 caractères ; 0 final)
PleinEcran:     FCB 0

Txt_Unknown:    FCN "Commande inconnue ou non executable"
Txt_Pause:      FCN "[ Appuyez sur une touche ]"

; U = pointeur d'écriture : ajoute le nom du fichier sélectionné (sans espaces)
Append_SelName:
    LDA     FileCount
    BEQ     ASN_End
    JSR     Sel_Name_Ptr
    LDB     #15
ASN_Loop:
    LDA     ,X+
    CMPA    #$20
    BEQ     ASN_End
    STA     ,U+
    DECB
    BNE     ASN_Loop
ASN_End:
    RTS

; ------------------------------------------------ Ouvrir (selon l'extension)
Act_Open:
    LDA     FileCount
    LBEQ    Event_Loop
    JSR     Sel_Name_Ptr
    LDA     15,X
    LBNE    Enter_Dir           ; un dossier : on y entre
    LDB     #15
AO_Dot:
    LDA     ,X+
    CMPA    #$2E                ; '.'
    BEQ     AO_Ext
    CMPA    #$20
    BEQ     AO_NoExt
    DECB
    BNE     AO_Dot
    BRA     AO_NoExt
AO_Ext:                         ; X -> les 3 caractères d'extension
    LDY     #ExtTable
AO_Search:
    LDA     ,Y
    BEQ     AO_NoExt            ; fin de table
    LDA     ,X
    CMPA    ,Y
    BNE     AO_Next
    LDA     1,X
    CMPA    1,Y
    BNE     AO_Next
    LDA     2,Y                 ; extension de deux lettres (« Z5 ») : finie
    CMPA    #$20                ; par une espace, ou par la fin du champ
    BNE     AO_Trois            ; (le point était le 13e : B = 3)
    CMPB    #3
    BEQ     AO_Trouve
    LDA     2,X
    CMPA    #$20
    BEQ     AO_Trouve
    BRA     AO_Next
AO_Trois:
    LDA     2,X
    CMPA    2,Y
    BNE     AO_Next
    LDA     3,X                 ; l'extension doit se terminer là :
    CMPA    #$20                ; une espace, ou la fin du champ de 15
    BEQ     AO_Trouve           ; caractères (B = 4 : le point était le
    CMPB    #4                  ; 12e, KOROBEINIKI.MUS ; 3,X est déjà hors
    BNE     AO_Next             ; du nom)
AO_Trouve:
    ; association trouvée : "PROGRAMME NOM"
    LDU     #CmdBuf
    LDX     3,Y
    PSHS    Y
    JSR     Append
    LDA     #$20
    STA     ,U+
    JSR     Append_SelName
    CLR     ,U
    PULS    Y
    LDA     5,Y
    STA     RunPause
    JSR     Run_Command
    JMP     After_Run
AO_Next:
    LEAY    6,Y
    BRA     AO_Search

AO_NoExt:                       ; pas d'association : exécutable ? on le lance
    JSR     Sel_Name_Ptr
    JSR     [table_function_ram+sys_FS_FindEntry]
    LBCS    AO_Fail
    LDA     g_find_fileInfo+27
    BITA    #$01
    LBEQ    AO_Fail
    LDU     #CmdBuf
    JSR     Append_SelName
    CLR     ,U
    LDA     #1                  ; programme en mode texte : on laisse lire la sortie
    STA     RunPause
    JSR     Run_Command
    JMP     After_Run

AO_Fail:                        ; rien à ouvrir : bip d'erreur
    JSR     Snd_Err
    LBRA    Event_Loop

; Extension (3 car.), programme, pause au retour (0/1)
ExtTable:
    FCC     "ASM"
    FDB     Prog_Edit
    FCB     0
    FCC     "TXT"
    FDB     Prog_Edit
    FCB     0
    FCC     "INC"
    FDB     Prog_Edit
    FCB     0
    FCC     "CAL"
    FDB     Prog_Calc
    FCB     0
    FCC     "MUS"
    FDB     Prog_AyJoue
    FCB     0
    FCC     "Z3 "                       ; fictions interactives (Z-machine)
    FDB     Prog_ZMachine
    FCB     0
    FCC     "Z5 "
    FDB     Prog_ZMachine
    FCB     0
    FCC     "Z8 "
    FDB     Prog_ZMachine
    FCB     0
    ; .BAS : pas d'association pour l'instant (BASIC se pilote depuis son propre prompt)
    FCB     0                   ; fin de table
Prog_Edit:      FCN "EDIT"          ; éditeur fenêtré (apps/edit.asm)
Prog_Calc:      FCN "CALC"          ; tableur (apps/calc.asm) : la feuille en argument
Prog_AyJoue:    FCN "AYJOUE"        ; morceau pour l'AY (cmd/ayjoue.asm, tools/ay/ay.py)
Prog_ZMachine:  FCN "ZMACHINE"      ; interpréteur Z-machine (zmachine/, le jeu en argument)

; ------------------------------------------------------------ Editer
Act_Edit:
    JSR     Sel_Not_Dir         ; un dossier ne s'édite pas
    LBCS    Event_Loop
    LDA     FileCount
    LBEQ    Event_Loop
    LDU     #CmdBuf
    LDX     #Prog_Edit
    JSR     Append
    LDA     #$20
    STA     ,U+
    JSR     Append_SelName
    CLR     ,U
    CLR     RunPause
    JSR     Run_Command
    JMP     After_Run

; ------------------------------------- Exécuter une commande (Tab / menu)
Act_Command:
    CLR     CmdBuf
    CLR     CmdLen
    LDA     FileCount
    BEQ     AC_NoPre
    JSR     Sel_Name_Ptr        ; fichier exécutable : préremplit "NOM "
    JSR     [table_function_ram+sys_FS_FindEntry]
    BCS     AC_NoPre
    LDA     g_find_fileInfo+27
    BITA    #$01
    BEQ     AC_NoPre
    LDU     #CmdBuf
    JSR     Append_SelName
    LDA     #$20
    STA     ,U+
    CLR     ,U
    TFR     U,D
    SUBD    #CmdBuf
    STB     CmdLen
AC_NoPre:
    LDA     #10                 ; boîte 60 x 8 en (10,10), ombre : 61 x 9
    STA     RectX
    LDA     #10
    STA     RectY
    LDA     #61
    STA     RectW
    LDA     #9
    STA     RectH
    JSR     Sync_Begin
    JSR     Rect_Save
    JSR     Sync_End

    JSR     Sync_Begin
    LDA     #10
    LDB     #10
    LDW     #(60*256)+8
    LDY     #Txt_CmdTitle
    JSR     Draw_Window
    JSR     Sync_End

    JSR     Sync_Begin
    LDA     #COLOR_TEXT
    STA     TextAttr
    LDA     #12
    LDB     #12
    LDX     #Txt_CmdLabel
    JSR     Put_Text
    LDA     #12
    LDB     #15
    LDX     #Txt_CmdHint
    JSR     Put_Text
    JSR     Sync_End

; Saisie : vis_Input (champ commun). Ctrl+F rend la main (INP_CTRL) pour
; insérer le nom du fichier, puis la saisie reprend sur le même tampon.
Cmd_Edit:
    LDA     #12
    LDB     #13
    LDX     #CmdBuf
    LDE     #CMD_MAX
    LDF     #INP_NON_VIDE+INP_CTRL
    LDY     #0
    JSR     Vis_Input
    STB     CmdLen
    BCS     Cmd_Cancel
    CMPA    #$0D
    BEQ     Cmd_Go
    CMPA    #$06                ; Ctrl+F : insère le nom du fichier
    BNE     Cmd_Edit            ; autre touche de contrôle : ignorée

Cmd_Name:
    LDB     CmdLen
    LDU     #CmdBuf
    LEAU    B,U
    JSR     Append_SelName
    CLR     ,U
    TFR     U,D
    SUBD    #CmdBuf
    CMPB    #CMD_MAX
    BLS     Cmd_NameOk
    LDB     #CMD_MAX            ; trop long : on coupe
Cmd_NameOk:
    STB     CmdLen
    LDX     #CmdBuf
    ABX
    CLR     ,X
    BRA     Cmd_Edit

Cmd_Cancel:
    JSR     Sync_Begin
    JSR     Rect_Restore
    JSR     Sync_End
    LBRA    Event_Loop

Cmd_Go:                         ; non vide : garanti par INP_NON_VIDE
    LDA     #1
    STA     RunPause
    JSR     Run_Command
    JMP     After_Run

Txt_CmdTitle:   FCN " Executer une commande "
Txt_CmdLabel:   FCN "Commande :"
Txt_CmdHint:    FCN "Ctrl+F: nom du fichier  Entree: lancer  Echap: annuler"


; ===================================================================
; POSITION DANS LA LISTE (retour de programme, suppression, renommage)
; ===================================================================

; Après un programme : mémorise le fichier sélectionné puis relance OSM-VISION
Return_From_Program:
    LDA     FileCount
    BEQ     RFP_Go
    JSR     Sel_Name_Ptr
    LDY     #SaveName
    LDW     #15
    TFM     X+,Y+
    LDA     Selection
    STA     SaveSel
    LDA     TopIndex
    STA     SaveTop
    LDA     #$A5
    STA     KeepPos
RFP_Go:
    JMP     Vision_Start

; A = indice voulu (déjà <= FileCount-1), SaveTop = haut de fenêtre voulu.
; Range Selection et TopIndex en respectant : 0 <= Top <= MaxTop,
; Top <= Selection <= Top+15.
Apply_Position:
    STA     Selection
    LDB     FileCount
    SUBB    #VISIBLE_ROWS
    BHS     AP_Max
    CLRB
AP_Max:                         ; B = MaxTop
    LDA     SaveTop
    PSHS    B
    CMPA    ,S+
    BLS     AP_1
    TFR     B,A                 ; Top = MaxTop
AP_1:
    CMPA    Selection
    BLS     AP_2
    LDA     Selection           ; Top <= Selection
AP_2:
    LDB     Selection
    SUBB    #VISIBLE_ROWS-1
    BLO     AP_3                ; Selection < 15
    PSHS    B
    CMPA    ,S+
    BHS     AP_3
    TFR     B,A                 ; Top >= Selection-15
AP_3:
    STA     TopIndex
    RTS

; Reprend l'indice SaveSel (borné au dernier fichier) et SaveTop
Restore_Index:
    LDA     FileCount
    BEQ     RI_Empty
    DECA                        ; dernier indice
    CMPA    SaveSel
    BLS     RI_Go
    LDA     SaveSel
RI_Go:
    LBRA    Apply_Position
RI_Empty:
    CLR     Selection
    CLR     TopIndex
    RTS

; Cherche SaveName dans la liste ; sinon retombe sur l'indice SaveSel
Restore_ByName:
    LDA     FileCount
    BEQ     RI_Empty
    CLR     RP_Idx
RB_Loop:
    LDA     RP_Idx
    LDB     #REC
    MUL
    LDX     #FileNames
    LEAX    D,X
    LDY     #SaveName
    LDB     #15
RB_Cmp:
    LDA     ,X+
    CMPA    ,Y+
    BNE     RB_Next
    DECB
    BNE     RB_Cmp
    LDA     RP_Idx              ; trouvé
    LBRA    Apply_Position
RB_Next:
    INC     RP_Idx
    LDA     RP_Idx
    CMPA    FileCount
    BLO     RB_Loop
    BRA     Restore_Index

; ===================================================================
; PROTECTION DES FICHIERS SYSTÈME
; Is_Protected : fichier sélectionné protégé -> C=1, sinon C=0
; ===================================================================
Is_Protected:
    JSR     Sel_Name_Ptr        ; X = nom (15 octets, complété d'espaces)
    LDY     #ProtTbl
IP_Entry:
    LDA     ,Y
    BEQ     IP_No               ; fin de table
    PSHS    X
IP_Cmp:
    LDA     ,Y+
    BEQ     IP_EndEntry
    CMPA    ,X+
    BEQ     IP_Cmp
IP_Skip:                        ; différent : on saute le reste de l'entrée
    LDA     ,Y+
    BNE     IP_Skip
    PULS    X
    BRA     IP_Entry
IP_EndEntry:
    LDA     ,X                  ; le nom sélectionné doit se terminer ici
    PULS    X
    CMPA    #$20
    BNE     IP_Entry
    ORCC    #$01
    RTS
IP_No:
    ANDCC   #$FE
    RTS

; Noms protégés (contre la suppression et le renommage) : à compléter
ProtTbl:
    FCN     "SHELL"
    FCN     "OSMVISION"
    FCB     0

Txt_Protected:  FCN "Ce fichier est protege."
Txt_ProtTitle:  FCN " Protege "

; Erreur pendant la suppression : message dans la boîte, puis fermeture
Del_Error:
    JSR     Snd_Err
    JSR     Sync_Begin
    LDA     #COLOR_TEXT
    STA     TextAttr
    LDA     #15
    LDB     #15
    LDX     #Txt_ErrDel
    JSR     Put_Text
    JSR     Sync_End
DE_Wait:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     DE_Wait
    LBRA    Del_Cancel
Txt_ErrDel:     FCN "Echec de la suppression     "

; ===================================================================
; RENOMMER
; ===================================================================
Act_Rename:
    JSR     Sel_Not_Parent
    LBCS    Event_Loop
    LDA     FileCount
    LBEQ    Event_Loop
    JSR     Is_Protected
    BCC     AR_Ok
    LDX     #Txt_Protected
    LDY     #Txt_ProtTitle
    JSR     Msg_Box
    LBRA    Event_Loop
AR_Ok:
    CLR     RenBuf              ; préremplit avec le nom actuel
    LDU     #RenBuf
    JSR     Append_SelName
    CLR     ,U
    TFR     U,D
    SUBD    #RenBuf
    STB     RenLen
    LDX     #Txt_RenTitle
    LDY     #Ren_Do
    JSR     Name_Dialog
    LBCS    Event_Loop
    LBRA    Reload_Select       ; relit le dossier, sélectionne NewName

; Ren_Do - NewName : renomme la sélection. C=1, X = message si impossible.
Ren_Do:
    JSR     Sel_Name_Ptr        ; identique à l'ancien nom : rien à faire
    LDY     #NewName
    LDB     #15
RG_Same:
    LDA     ,X+
    CMPA    ,Y+
    BNE     RG_Diff
    DECB
    BNE     RG_Same
    ANDCC   #$FE
    RTS
RG_Diff:
    JSR     Name_Exists         ; dans ce dossier (pas de repli sur la racine)
    BCC     RG_Free
    LDX     #Txt_ErrExists
    ORCC    #1
    RTS
RG_Free:
    JSR     Sel_Name_Ptr
    LDY     #NewName
    JSR     [table_function_ram+sys_FS_RenameFile]
    BCC     RG_Ok
    LDX     #Txt_ErrRename
RG_Ok:
    RTS

; Name_Exists - NewName existe-t-il dans le dossier courant ? C=1 oui.
; (FS_FileInfo : sans le repli sur la racine de FS_FindEntry.)
Name_Exists:
    LDX     #NewName
    LDY     #InfoBuf
    JSR     [table_function_ram+sys_FS_FileInfo]
    BCS     NE_Non
    ORCC    #1
    RTS
NE_Non:
    ANDCC   #$FE
    RTS

; Name_Dialog - Boîte de saisie d'un nom (40 x 8 en 20,10).
; Entrée : X = titre, Y = action ; RenBuf/RenLen préremplis.
; L'action reçoit NewName (la saisie complétée à 15 par des espaces) :
; C=0 fait (la boîte se ferme), C=1 et X = message (on reste dans la saisie).
; Sortie : C=0 action faite, C=1 annulé (Echap).
Name_Dialog:
    STX     DlgTitle
    STY     DlgAction
    LDA     #20                 ; boîte 40 x 8 en (20,10), ombre : 41 x 9
    STA     RectX
    LDA     #10
    STA     RectY
    LDA     #41
    STA     RectW
    LDA     #9
    STA     RectH
    JSR     Sync_Begin
    JSR     Rect_Save
    JSR     Sync_End

    JSR     Sync_Begin
    LDA     #20
    LDB     #10
    LDW     #(40*256)+8
    LDY     DlgTitle
    JSR     Draw_Window
    JSR     Sync_End

    JSR     Sync_Begin
    LDA     #COLOR_TEXT
    STA     TextAttr
    LDA     #22
    LDB     #12
    LDX     #Txt_RenLabel
    JSR     Put_Text
    LDA     #22
    LDB     #15
    LDX     #Txt_RenHint
    JSR     Put_Text
    JSR     Sync_End

; Saisie : vis_Input (champ commun). Ren_Hint, appelé à chaque touche,
; efface un éventuel message d'erreur de la ligne d'aide.
Ren_Edit:
    LDA     #22
    LDB     #13
    LDX     #RenBuf
    LDE     #REN_MAX
    LDF     #INP_MAJ+INP_SANS_ESPACE+INP_NON_VIDE
    LDY     #Ren_Hint
    JSR     Vis_Input
    STB     RenLen
    BCC     Ren_Go

Ren_Cancel:
    JSR     Snd_Back
    JSR     Sync_Begin
    JSR     Rect_Restore
    JSR     Sync_End
    ORCC    #1
    RTS

Ren_Go:                         ; non vide : garanti par INP_NON_VIDE
    LDX     #RenBuf             ; pas de '/' : un nom, pas un chemin
RG_Slash:
    LDA     ,X+
    BEQ     RG_NoSlash
    CMPA    #'/'
    BNE     RG_Slash
    LDX     #Txt_ErrSlash
    JSR     Ren_Error
    BRA     Ren_Edit
RG_NoSlash:
    LDX     #RenBuf             ; NewName = saisie complétée à 15 par des espaces
    LDY     #NewName
    LDB     #15
RG_Fmt:
    LDA     ,X+
    BEQ     RG_Pad
    STA     ,Y+
    DECB
    BNE     RG_Fmt
    BRA     RG_Done
RG_Pad:
    LDA     #$20
RG_PadLoop:
    STA     ,Y+
    DECB
    BNE     RG_PadLoop
RG_Done:
    JSR     [DlgAction]
    BCC     RG_Fait
    JSR     Ren_Error
    LBRA    Ren_Edit
RG_Fait:
    JSR     Snd_Ok
    ; La boîte (20..60) déborde à droite de la fenêtre principale
    ; (10..50) : Full_Redraw ne repeint que celle-ci, il faut donc
    ; d'abord remettre le dessous de la boîte.
    JSR     Sync_Begin
    JSR     Rect_Restore
    JSR     Sync_End
    ANDCC   #$FE
    RTS

; Reload_Select - relit le dossier, sélectionne NewName, redessine.
Reload_Select:
    LDX     #NewName
    LDY     #SaveName
    LDW     #15
    TFM     X+,Y+
    LDA     Selection
    STA     SaveSel
    LDA     TopIndex
    STA     SaveTop
    JSR     Load_Directory
    JSR     Restore_ByName
    JSR     Full_Redraw
    LBRA    Event_Loop

; ------------------------------------------------------- Nouveau dossier
Act_NewDir:
    CLR     RenBuf
    CLR     RenLen
    LDX     #Txt_NewDirTitle
    LDY     #NewDir_Do
    JSR     Name_Dialog
    LBCS    Event_Loop
    LBRA    Reload_Select

NewDir_Do:
    JSR     Name_Exists
    BCC     ND_Libre
    LDX     #Txt_ErrExists
    RTS
ND_Libre:
    LDX     #NewName
    JSR     [table_function_ram+sys_FS_MkDir]
    BCC     ND_Ok
    LDX     #Txt_ErrMkDir
ND_Ok:
    RTS

; ------------------------------------------------ Copier / Couper / Coller
; Le presse-papiers : un nom (ClipName), son dossier (ClipDir, n°), et
; ClipMode (0 vide, 1 copier, 2 couper). Coller le retrouve par un chemin
; complet reconstruit ("/APPS/JEUX/NOM"), comme Format_Filename_83 les lit.
Act_Copy:
    LDA     #1
    BRA     Clip_Take
Act_Cut:
    LDA     #2
Clip_Take:
    LDB     FileCount
    LBEQ    Event_Loop
    PSHS    A
    JSR     Sel_Name_Ptr
    LDB     15,X
    BITB    #FL_PARENT          ; pas ".."
    BNE     CT_Non
    BITB    #FL_DIR             ; un dossier se coupe, ne se copie pas (encore)
    BEQ     CT_Ok
    LDA     ,S
    CMPA    #1
    BNE     CT_Ok
    PULS    A
    LDX     #Txt_ErrCopyDir
    LDY     #Txt_ClipTitle
    JSR     Msg_Box
    LBRA    Event_Loop
CT_Ok:
    PULS    A
    STA     ClipMode
    LDY     #ClipName
    LDW     #15
    TFM     X+,Y+
    LDD     #$FFFF
    JSR     [table_function_ram+sys_FS_Dossier]
    STD     ClipDir
    JSR     Snd_Ok
    LBRA    Event_Loop
CT_Non:
    PULS    A
    LBRA    Event_Loop

Act_Paste:
    LDA     ClipMode
    BNE     AP_Go
    LDX     #Txt_ErrClipEmpty
    LBRA    AP_Msg
AP_Go:
    LDX     #ClipName           ; le nom d'arrivée : le même, ici
    LDY     #NewName
    LDW     #15
    TFM     X+,Y+
    LDD     #$FFFF
    JSR     [table_function_ram+sys_FS_Dossier]
    CMPD    ClipDir
    BNE     AP_Autre
    LDX     #Txt_ErrSameDir     ; déjà ici
    LBRA    AP_Msg
AP_Autre:
    JSR     Name_Exists
    BCC     AP_Libre
    LDX     #Txt_ErrExists
    LBRA    AP_Msg
AP_Libre:
    JSR     Clip_Source         ; SrcName : le fichier d'origine, par son chemin
    LDA     ClipMode
    CMPA    #2
    BEQ     AP_Move
    ; --- copier : pages 2-3 (64 Ko au plus), puis page, adresse, attributs ---
    LDX     #SrcName
    LDY     #InfoBuf
    JSR     [table_function_ram+sys_FS_FileInfo]
    BCS     AP_ErrRead
    LDD     InfoBuf+4           ; plus de 64 Ko ?
    BNE     AP_TooBig
    LDA     #2
    LDX     #SrcName
    LDY     #$0000
    JSR     [table_function_ram+sys_FS_LoadFile]
    BCS     AP_ErrRead
    LDA     #2
    LDX     #NewName
    LDY     #$0000
    LDU     InfoBuf+6
    JSR     [table_function_ram+sys_FS_SaveFile]
    BCS     AP_ErrWrite
    LDX     #NewName
    LDA     InfoBuf+8
    LDY     InfoBuf+9
    JSR     [table_function_ram+sys_FS_SetLoad]
    LDX     #NewName
    LDA     InfoBuf+11
    JSR     [table_function_ram+sys_FS_SetAttributes]
    BRA     AP_Fait
AP_Move:
    LDX     #SrcName
    LDY     #NewName
    JSR     [table_function_ram+sys_FS_RenameFile]
    BCS     AP_ErrMove
    CLR     ClipMode            ; coupé-collé : le presse-papiers se vide
AP_Fait:
    JSR     Snd_Ok
    LBRA    Reload_Select
AP_TooBig:
    LDX     #Txt_ErrTooBig
    BRA     AP_Msg
AP_ErrRead:
    LDX     #Txt_ErrRead
    BRA     AP_Msg
AP_ErrWrite:
    LDX     #Txt_ErrWrite
    BRA     AP_Msg
AP_ErrMove:
    LDX     #Txt_ErrMove
AP_Msg:
    LDY     #Txt_ClipTitle
    JSR     Msg_Box
    LBRA    Event_Loop

; Clip_Source - SrcName = "/chemin/de/ClipDir/ClipName", formaté.
Clip_Source:
    LDU     #PathIds            ; remonter de ClipDir à la racine
    CLR     PathN
    LDD     ClipDir
CS_Up:
    CMPD    #0
    BEQ     CS_Out
    PSHS    D
    LDA     PathN
    CMPA    #PATH_NIV
    PULS    D
    BHS     CS_Out
    STD     ,U++
    INC     PathN
    LDY     #0
    JSR     [table_function_ram+sys_FS_DirInfo]   ; D = parent
    BCC     CS_Up
CS_Out:
    LDX     #PathBuf
    LDA     #'/'
    STA     ,X+
CS_Down:
    TST     PathN
    BEQ     CS_Nom
    LDD     ,--U
    LDY     #NomTmp
    JSR     [table_function_ram+sys_FS_DirInfo]
    LDY     #NomTmp
    JSR     CS_Mot
    LDA     #'/'
    STA     ,X+
    DEC     PathN
    BRA     CS_Down
CS_Nom:
    LDY     #ClipName
    JSR     CS_Mot
    CLR     ,X
    LDX     #PathBuf
    LDY     #SrcName
    JMP     [table_function_ram+sys_Format_Filename_83]
; CS_Mot - copie le nom de 15 octets en Y (sans les espaces) en X.
CS_Mot:
    LDB     #15
CSM_Lp:
    LDA     ,Y+
    CMPA    #' '
    BEQ     CSM_Fin
    STA     ,X+
    DECB
    BNE     CSM_Lp
CSM_Fin:
    RTS

; X = message : l'affiche sur la ligne d'aide de la boîte
Ren_Error:
    STX     MsgText
    JSR     Snd_Err
    JSR     Sync_Begin
    LDA     #COLOR_TEXT
    STA     TextAttr
    LDA     #22
    LDB     #15
    LDX     MsgText
    JSR     Put_Text
    JSR     Sync_End
    RTS

; Crochet de vis_Input : réécrit la ligne d'aide, ce qui efface un
; message d'erreur laissé par Ren_Error.
Ren_Hint:
    LDA     #COLOR_TEXT
    STA     TextAttr
    LDA     #22
    LDB     #15
    LDX     #Txt_RenHint
    JMP     Put_Text

Txt_RenTitle:   FCN " Renommer "
Txt_RenLabel:   FCN "Nouveau nom :"
Txt_RenHint:    FCN "Entree : valider   Echap : annuler  "
Txt_ErrExists:  FCN "Ce nom existe deja !                "
Txt_ErrRename:  FCN "Echec du renommage                  "
Txt_ErrSlash:   FCN "Pas de / dans un nom                "
Txt_ErrMkDir:   FCN "Echec de la creation                "
Txt_NewDirTitle: FCN " Nouveau dossier "
Txt_ClipTitle:  FCN " Presse-papiers "
Txt_ErrClipEmpty: FCN "Rien a coller : Copier ou Couper d'abord."
Txt_ErrSameDir: FCN "Le fichier est deja dans ce dossier."
Txt_ErrCopyDir: FCN "Un dossier se coupe, il ne se copie pas."
Txt_ErrTooBig:  FCN "Fichier de plus de 64 Ko : pas de copie."
Txt_ErrRead:    FCN "Lecture impossible."
Txt_ErrWrite:   FCN "Ecriture impossible."
Txt_ErrMove:    FCN "Deplacement impossible."


; ===================================================================
; VOIR : visualiseur de fichier (texte ou hexadécimal), 32 Ko maximum
; Le fichier est chargé dans SCRATCH_PAGE ; on le relit par morceaux
; avec FarRead (A = page source, B = page destination, X = source,
; Y = destination, U = taille).
; ===================================================================
Act_View:
    JSR     Sel_Not_Dir
    LBCS    Event_Loop
    LDA     FileCount
    LBEQ    Event_Loop
    JSR     Sel_Name_Ptr
    JSR     [table_function_ram+sys_FS_FindEntry]
    LBCS    Event_Loop
    LDD     g_find_fileInfo+20          ; poids fort de la taille
    LBNE    AV_TooBig
    LDD     g_find_fileInfo+22          ; taille (16 bits)
    STD     ViewSize
    LBEQ    AV_Empty
    CMPD    #$8000
    LBHI    AV_TooBig

    JSR     Snd_Wait                    ; pas de son pendant un changement de page
    JSR     Sel_Name_Ptr                ; charge dans la page tampon, en $0000
    LDA     #SCRATCH_PAGE
    LDY     #0
    JSR     [table_function_ram+sys_FS_LoadFile]
    LBCS    AV_ReadErr

    CLR     ViewMode                    ; 0 = texte, 1 = hexadécimal
    CLR     ViewTop
    CLR     ViewTop+1
    JSR     View_BuildIndex
    JSR     View_SetRows
    JSR     View_Open
    JSR     View_Update

View_Loop:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     View_Loop
    CMPA    #$1B
    LBEQ    View_Close
    CMPA    #$20
    LBEQ    View_Close
    LDX     ViewTop                     ; position avant la touche
    STX     ViewOld
    CMPA    #$80
    BEQ     VL_Up
    CMPA    #$81
    BEQ     VL_Down
    CMPA    #$82
    BEQ     VL_PgUp
    CMPA    #$83
    BEQ     VL_PgDn
    CMPA    #KEY_PGUP
    BEQ     VL_PgUp
    CMPA    #KEY_PGDN
    BEQ     VL_PgDn
    CMPA    #KEY_HOME           ; Début / Fin du fichier affiché
    BEQ     VL_Home
    CMPA    #KEY_END
    BEQ     VL_End
    CMPA    #$09
    BEQ     VL_Mode
    LBRA    View_Loop

VL_Up:
    LDD     ViewTop
    LBEQ    View_Loop
    SUBD    #1
    BRA     VL_Set
VL_Down:
    LDD     ViewTop
    ADDD    #1
    BRA     VL_Set
VL_PgUp:
    LDD     ViewTop
    SUBD    #VIEW_ROWS
    BCC     VL_Set
    LDD     #0
    BRA     VL_Set
VL_PgDn:
    LDD     ViewTop
    ADDD    #VIEW_ROWS
    BRA     VL_Set
VL_Home:
    LDD     #0
    BRA     VL_Set
VL_End:
    LDD     #$FFFF              ; View_Clamp ramène à la dernière page
VL_Set:
    STD     ViewTop
    JSR     View_Clamp
    LDD     ViewTop
    CMPD    ViewOld
    LBEQ    View_Loop                   ; rien n'a bougé
    BRA     VL_Draw
VL_Mode:
    LDA     ViewMode
    EORA    #1
    STA     ViewMode
    CLR     ViewTop
    CLR     ViewTop+1
    JSR     View_SetRows
VL_Draw:
    JSR     View_Update
    LBRA    View_Loop

View_Close:                             ; redessine l'explorateur complet
    JSR     Draw_Base_UI
    JSR     Aide_Si
    JSR     Draw_FileList
    LBRA    Event_Loop

AV_TooBig:
    LDX     #Txt_TooBig
    BRA     AV_Msg
AV_Empty:
    LDX     #Txt_Empty
    BRA     AV_Msg
AV_ReadErr:
    LDX     #Txt_ReadErr
AV_Msg:
    LDY     #Txt_ViewTitle
    JSR     Msg_Box
    LBRA    Event_Loop

Txt_ViewTitle:  FCN " Voir "
Txt_TooBig:     FCN "Fichier trop gros (32 Ko maximum)."
Txt_Empty:      FCN "Fichier vide."
Txt_ReadErr:    FCN "Erreur de lecture du fichier."
Txt_VText:      FCN "Texte  ligne "
Txt_VHex:       FCN "Hexa   ligne "
Txt_VHelp:      FCN "   Tab : texte/hexa   Echap : fermer"

; --- Nombre de lignes à afficher selon le mode ---
View_SetRows:
    LDA     ViewMode
    BNE     VSR_Hex
    LDD     LineCnt
    STD     ViewRows
    RTS
VSR_Hex:
    LDD     ViewSize                    ; ceil(taille / 16)
    ADDD    #15
    LSRA
    RORB
    LSRA
    RORB
    LSRA
    RORB
    LSRA
    RORB
    STD     ViewRows
    RTS

; --- ViewTop <= max(0, ViewRows - VIEW_ROWS) ---
View_Clamp:
    LDD     ViewRows
    SUBD    #VIEW_ROWS
    BCC     VC_Max
    LDD     #0
VC_Max:
    CMPD    ViewTop
    BHS     VC_Ok
    STD     ViewTop
VC_Ok:
    RTS

; --- Index des débuts de ligne (mode texte) : LineTbl[i], LineCnt ---
View_BuildIndex:
    LDD     #0
    STD     LineTbl
    STD     ScanOff
    LDD     #1
    STD     LineCnt
    LDD     #LineTbl+2
    STD     LTPtr
VBI_Chunk:
    LDD     ViewSize
    SUBD    ScanOff
    LBLS    VBI_Done                    ; plus rien à lire
    CMPD    #256
    BLS     VBI_Len
    LDD     #256
VBI_Len:
    STD     ChunkLen
    TFR     D,U
    LDA     #SCRATCH_PAGE
    LDB     current_page
    LDX     ScanOff
    LDY     #ChunkBuf
    JSR     [table_function_ram+sys_FarRead]

    LDX     #ChunkBuf                   ; X = octet courant
    LDY     ScanOff                     ; Y = position dans le fichier
    LDU     ChunkLen                    ; U = octets restants
VBI_Scan:
    LEAY    1,Y                         ; Y = position après cet octet
    LDA     ,X+
    CMPA    #$0A
    BNE     VBI_Next
    CMPY    ViewSize                    ; une ligne commence là si on n'est pas à la fin
    BHS     VBI_Next
    LDD     LineCnt
    CMPD    #MAX_LINES
    BHS     VBI_Next
    STY     [LTPtr]
    LDD     LTPtr
    ADDD    #2
    STD     LTPtr
    LDD     LineCnt
    ADDD    #1
    STD     LineCnt
VBI_Next:
    LEAU    -1,U
    CMPU    #0
    BNE     VBI_Scan
    LDD     ScanOff
    ADDD    ChunkLen
    STD     ScanOff
    LBRA    VBI_Chunk
VBI_Done:
    RTS

; --- Dessine la fenêtre et colore la zone de texte (page 0 du générateur) ---
View_Open:
    JSR     Sync_Begin
    LDA     #VIEW_X
    LDB     #VIEW_Y
    LDW     #(VIEW_W*256)+VIEW_H
    LDY     #Txt_ViewTitle
    JSR     Draw_Window
    JSR     Sync_End

    LDA     #COLOR_TEXT
    STA     ColorByte
    CLR     ViewI
VO_Next:
    JSR     Sync_Begin
    LDA     #5                          ; 5 lignes par lot
    STA     ViewJ
VO_Row:
    LDA     #VIEW_TX
    LDB     ViewI
    ADDB    #VIEW_TY
    JSR     Calc_Addr
    LEAY    VRAM_COL_OFS,Y              ; plan couleurs
    IFNE    CARTE_MONO
    LDA     ColorByte                   ; mono : une couleur sur deux octets
    LDB     #VIEW_COLS
VO_Case:
    STA     ,Y++
    DECB
    BNE     VO_Case
    ELSE
    LDX     #ColorByte
    LDW     #VIEW_COLS
    TFM     X,Y+                        ; remplit avec l'octet pointé par X
    ENDC
    INC     ViewI
    LDA     ViewI
    CMPA    #VIEW_ROWS
    BHS     VO_Done
    DEC     ViewJ
    BNE     VO_Row
    JSR     Sync_End
    BRA     VO_Next
VO_Done:
    JSR     Sync_End
    RTS

; --- Compose l'écran dans ViewBuf, le copie en VRAM, met à jour le statut ---
View_Update:
    JSR     View_Compose
    JSR     View_Blit
    JSR     View_Status
    RTS

View_Compose:
    LDA     #ASCII_SPACE
    STA     SpaceByte
    LDX     #SpaceByte
    LDY     #ViewBuf
    LDW     #VIEW_COLS*VIEW_ROWS
    TFM     X,Y+
    CLR     ViewI
VCo_Row:
    LDD     ViewTop
    ADDB    ViewI
    ADCA    #0
    CMPD    ViewRows
    BHS     VCo_End                     ; au-delà de la fin du fichier
    STD     ViewLine
    LDA     ViewMode
    BNE     VCo_Hex
    JSR     View_TextRow
    BRA     VCo_Next
VCo_Hex:
    JSR     View_HexRow
VCo_Next:
    INC     ViewI
    LDA     ViewI
    CMPA    #VIEW_ROWS
    BLO     VCo_Row
VCo_End:
    RTS

; U = début de la ligne ViewI dans ViewBuf
View_RowPtr:
    LDA     ViewI
    LDB     #VIEW_COLS
    MUL
    ADDD    #ViewBuf
    TFR     D,U
    RTS

View_TextRow:
    JSR     View_RowPtr
    LDD     ViewLine                    ; X = &LineTbl[ViewLine]
    ASLB
    ROLA
    ADDD    #LineTbl
    TFR     D,X
    LDD     ,X
    STD     ViewPos                     ; début de la ligne
    LDD     ViewLine                    ; fin = début de la suivante, ou fin du fichier
    ADDD    #1
    CMPD    LineCnt
    BHS     VTR_Last
    LDD     2,X
    BRA     VTR_Len
VTR_Last:
    LDD     ViewSize
VTR_Len:
    SUBD    ViewPos                     ; longueur de la ligne
    CMPD    #VIEW_COLS
    BLS     VTR_Fit
    LDD     #VIEW_COLS                  ; tronquée à la largeur de l'écran
VTR_Fit:
    STD     ChunkLen
    PSHS    U
    TFR     D,U
    LDA     #SCRATCH_PAGE
    LDB     current_page
    LDX     ViewPos
    LDY     #LineTmp
    JSR     [table_function_ram+sys_FarRead]
    PULS    U
    LDX     #LineTmp
    LDB     ChunkLen+1
VTR_Conv:
    LDA     ,X+
    CMPA    #$0A
    BEQ     VTR_Done
    CMPA    #$0D
    BEQ     VTR_Done
    CMPA    #$09                        ; tabulation -> espace
    BNE     VTR_NotTab
    LDA     #$20
    BRA     VTR_Put
VTR_NotTab:
    CMPA    #$20
    BLO     VTR_Dot
    CMPA    #$7E
    BLS     VTR_Put
VTR_Dot:
    LDA     #$2E                        ; '.'
VTR_Put:
    STA     ,U+
    DECB
    BNE     VTR_Conv
VTR_Done:
    RTS

; Ligne hexa : "OOOO  HH HH ... HH  cccccccccccccccc" (71 colonnes)
View_HexRow:
    JSR     View_RowPtr
    LDD     ViewLine                    ; décalage = ligne * 16
    ASLB
    ROLA
    ASLB
    ROLA
    ASLB
    ROLA
    ASLB
    ROLA
    STD     ViewPos
    LDD     ViewSize
    SUBD    ViewPos
    CMPD    #16
    BLS     HR_N
    LDD     #16
HR_N:
    STD     ChunkLen
    PSHS    U
    TFR     D,U
    LDA     #SCRATCH_PAGE
    LDB     current_page
    LDX     ViewPos
    LDY     #LineTmp
    JSR     [table_function_ram+sys_FarRead]
    PULS    U

    LDA     ViewPos
    JSR     Hex8
    LDA     ViewPos+1
    JSR     Hex8
    LDA     #$20
    STA     ,U+
    STA     ,U+
    LDX     #LineTmp
    CLR     ViewJ
HR_Hex:
    LDA     ViewJ
    CMPA    ChunkLen+1
    BHS     HR_Blank
    LDA     ,X+
    JSR     Hex8
    LDA     #$20
    STA     ,U+
    BRA     HR_NextH
HR_Blank:
    LDA     #$20
    STA     ,U+
    STA     ,U+
    STA     ,U+
HR_NextH:
    INC     ViewJ
    LDA     ViewJ
    CMPA    #16
    BLO     HR_Hex
    LDA     #$20
    STA     ,U+
    LDX     #LineTmp
    LDB     ChunkLen+1
HR_Asc:
    TSTB
    BEQ     HR_End
    LDA     ,X+
    CMPA    #$20
    BLO     HR_Dot
    CMPA    #$7E
    BLS     HR_Put
HR_Dot:
    LDA     #$2E
HR_Put:
    STA     ,U+
    DECB
    BRA     HR_Asc
HR_End:
    RTS

; Copie ViewBuf en VRAM (plan caractères) par lots de 10 lignes avec TFM
View_Blit:
    LDX     #ViewBuf
    STX     VBPtr
    CLR     ViewI
VB_Next:
    JSR     Sync_Begin
    LDA     #10
    STA     ViewJ
VB_Row:
    LDA     #VIEW_TX
    LDB     ViewI
    ADDB    #VIEW_TY
    JSR     Calc_Addr
    LDX     VBPtr
    IFNE    CARTE_MONO
    LDB     #VIEW_COLS                  ; mono : un caractère sur deux octets
VB_Case:
    LDA     ,X+
    STA     ,Y++
    DECB
    BNE     VB_Case
    ELSE
    LDW     #VIEW_COLS
    TFM     X+,Y+
    ENDC
    STX     VBPtr
    INC     ViewI
    LDA     ViewI
    CMPA    #VIEW_ROWS
    BHS     VB_Done
    DEC     ViewJ
    BNE     VB_Row
    JSR     Sync_End
    BRA     VB_Next
VB_Done:
    JSR     Sync_End
    RTS

; Ligne de statut : "Texte  ligne 12/340   Tab : ..."
View_Status:
    LDU     #TmpStr
    LDA     ViewMode
    BNE     VS_H
    LDX     #Txt_VText
    BRA     VS_Go
VS_H:
    LDX     #Txt_VHex
VS_Go:
    JSR     Append
    LDD     ViewTop
    ADDD    #1
    JSR     Dec16
    LDA     #$2F
    STA     ,U+
    LDD     ViewRows
    JSR     Dec16
    LDX     #Txt_VHelp
    JSR     Append
VS_Pad:
    TFR     U,D
    SUBD    #TmpStr
    CMPB    #70
    BHS     VS_Done
    LDA     #$20
    STA     ,U+
    BRA     VS_Pad
VS_Done:
    CLR     ,U
    JSR     Sync_Begin
    LDA     #COLOR_TEXT
    STA     TextAttr
    LDA     #4
    LDB     #VIEW_STATUS_ROW
    LDX     #TmpStr
    JSR     Put_Text
    JSR     Sync_End
    RTS


; ===================================================================
; APPLICATIONS FENÊTRÉES (attribut 'a')
; Elles tournent DANS OSM-VISION : pas de console, pas d'effacement.
;   - chargées à leur adresse de boot (>= APP_BASE) dans la page courante,
;     par FS_LoadFile (OSM-VISION reste donc résident en $0000..)
;   - argv / argc / input_buffer déjà remplis par Run_Command
;   - les deux plans de l'écran sont sauvegardés avant l'appel et
;     restaurés au retour (l'application rend la main par RTS)
; ===================================================================
; Une application tourne dans SA page (celle de son entrée, page 1 en
; général, liée à $0000) : chargée là, appelée par FAR_CALL, qui rend notre
; page au retour. Une application d'avant (page 0, liée à $4000, appelant
; nos services à adresse fixe) écraserait OSM-VISION : refusée.
RC_App:
    LDD     g_find_fileInfo+20          ; taille > 64 Ko ?
    LBNE    RC_AppBad
    LDA     g_find_fileInfo+24          ; sa page
    LBEQ    RC_AppVieille
    CMPA    #3
    LBHI    RC_AppBad
    STA     AppPage
    LDD     g_find_fileInfo+25          ; adresse de boot = point d'entrée
    STD     AppEntry
    LDD     g_find_fileInfo+22          ; entrée + taille doit rester sous $8000
    ADDD    AppEntry
    LBCS    RC_AppBad
    CMPD    #$8000
    LBHI    RC_AppBad
    JSR     Snd_Select
    JSR     Snd_Wait                    ; pas de son pendant un changement de page
    LDA     AppPage
    LDX     #FormattedName
    LDY     AppEntry
    JSR     [table_function_ram+sys_FS_LoadFile]
    LBCS    RC_AppErr
    JSR     Screen_Save
    LDA     AppPage
    LDX     AppEntry
    JSR     [table_function_ram+sys_Far_Call]   ; sa page ; RTS : la nôtre
    JSR     Snd_Stop                    ; sa partition est dans une zone qui va être réutilisée
    JSR     Screen_Restore
    LDA     #1
    STA     AppRan
    RTS
RC_AppVieille:
    LDX     #Txt_AppVieille
    BRA     RC_AppMsg
RC_AppBad:
    LDX     #Txt_AppBad
    BRA     RC_AppMsg
RC_AppErr:
    LDX     #Txt_ReadErr
RC_AppMsg:
    LDY     #Txt_ErrTitle
    JSR     Msg_Box
    LDA     #1
    STA     AppRan
    RTS

Txt_AppBad:     FCN "Application invalide (adresse ou taille)."
Txt_AppVieille: FCN "Application pour la page 0 : la reassembler."
Txt_ErrTitle:   FCN " Erreur "

; ===================================================================
; TERMINAL : le SHELL (lié à $6000, page 0 : à côté de nous) dans une
; fenêtre. La console du BIOS est limitée à l'intérieur de la fenêtre
; (sys_Console_Zone) ; les commandes de /BIN tournent en page 1 et
; écrivent dans la même zone. EXIT : on remet la console plein écran et
; on repart comme après un programme (le SHELL a pu changer de dossier).
; ===================================================================
TERM_X          equ 1           ; fenêtre (cadre compris), ombre en plus
TERM_Y          equ 2
TERM_W          equ 78
TERM_H          equ 22
TERM_ATTR       equ $0A         ; vert clair sur noir

Act_Terminal:
    JSR     Terminal_Run
    LBCS    Event_Loop                  ; message déjà affiché
    LBRA    Return_From_Program

; Terminal_Run : charge le SHELL, la fenêtre, la zone, l'appelle ; au retour,
; console plein écran. C = 1 : introuvable ou invalide (message affiché).
Terminal_Run:
    LDX     #Nom_Shell
    LDY     #FormattedName
    LDW     #15
    TFM     X+,Y+
    LDX     #FormattedName
    JSR     [table_function_ram+sys_FS_FindEntry]    ; /BIN, puis la racine
    LBCS    AT_Absent
    LDA     g_find_fileInfo+24          ; page 0, entre $4000 et $8000
    LBNE    AT_Mauvais
    LDD     g_find_fileInfo+25
    CMPD    #$4000
    LBLO    AT_Mauvais
    STD     AppEntry
    ADDD    g_find_fileInfo+22
    LBCS    AT_Mauvais
    CMPD    #$8000
    LBHI    AT_Mauvais
    JSR     Snd_Stop
    CLRA
    LDX     #FormattedName
    LDY     AppEntry
    JSR     [table_function_ram+sys_FS_LoadFile]
    LBCS    AT_Lecture
    LDY     #Txt_TermTitre
    JSR     Term_Ouvre
    LDX     AppEntry
    JSR     ,X                          ; le SHELL ; EXIT : retour ici
    JSR     Term_Ferme
    ANDCC   #$FE
    RTS

; Term_Ouvre : la fenêtre du Terminal (titre en Y, 0 final) et la console du
; BIOS limitée à son intérieur. Term_Ferme : console plein écran.
Term_Ouvre:
    JSR     Sync_Begin
    LDA     #TERM_X
    LDB     #TERM_Y
    LDW     #(TERM_W*256)+TERM_H
    JSR     Draw_Window
    JSR     Sync_End
    LDA     #TERM_X+1
    LDB     #TERM_Y+1
    LDE     #TERM_W-2
    LDF     #TERM_H-2
    LDY     #TERM_ATTR
    JSR     [table_function_ram+sys_Console_Zone]
    BRA     Curseur_On
Term_Ferme:
    CLRE
    JSR     [table_function_ram+sys_Console_Zone]
    BRA     Curseur_Off

; Curseur matériel (R10 du 68B45) : visible pour un programme console,
; caché pour le bureau. IRQ masquées : l'IRQ VSYNC choisit R14/R15 par le
; même registre d'index. Préserve tout sauf CC.
Curseur_On:
    PSHS    A,CC
    LDA     #CURSEUR_VISIBLE
    BRA     Curseur_R10
Curseur_Off:
    PSHS    A,CC
    LDA     #CURSEUR_CACHE
Curseur_R10:
    ORCC    #%01010000
    PSHS    A
    LDA     #10
    STA     CRTC_RS
    PULS    A
    STA     CRTC_DATA
    PULS    A,CC,PC
AT_Absent:
    LDX     #Txt_ShellAbsent
    BRA     AT_Msg
AT_Mauvais:
    LDX     #Txt_ShellMauvais
    BRA     AT_Msg
AT_Lecture:
    LDX     #Txt_ReadErr
AT_Msg:
    LDY     #Txt_ErrTitle
    JSR     Msg_Box
    ORCC    #$01
    RTS

Nom_Shell:        FCC "SHELL          "     ; 15 caractères
Txt_TermTitre:    FCN " Terminal "
Txt_ShellAbsent:  FCN "SHELL introuvable (dans /BIN ?)."
Txt_ShellMauvais: FCN "SHELL doit etre en page 0, entre $4000 et $8000."

; Après un programme : une application fenêtrée a déjà tout restauré à
; l'écran, on reprend directement ; un programme console recharge l'interface.
After_Run:
    LDA     AppRan
    LBEQ    Return_From_Program
    CLR     AppRan
    JMP     Event_Loop

; --- Sauvegarde / restauration des 2 plans visibles (2 x 2000 octets) ---
Screen_Save:
    CLR     ScrDir
    BRA     Screen_Copy
Screen_Restore:
    LDA     #1
    STA     ScrDir
Screen_Copy:
    LDU     #ScreenSave
    LDX     #VRAM_BASE
    LDA     #8                          ; 2 plans x 4 morceaux de 500 octets
    STA     ScrCnt
SC_Next:
    PSHS    X,U
    JSR     Sync_Begin
    PULS    X,U
    LDW     #500
    TST     ScrDir
    BNE     SC_Rest
    TFM     X+,U+                       ; VRAM -> mémoire
    BRA     SC_Done
SC_Rest:
    TFM     U+,X+                       ; mémoire -> VRAM
SC_Done:
    PSHS    X,U
    JSR     Sync_End
    PULS    X,U
    DEC     ScrCnt
    BEQ     SC_End
    IFNE    CARTE_MONO
    BRA     SC_Next                     ; mono : les 2000 cases font 4000 octets d'un bloc
    ELSE
    LDA     ScrCnt
    CMPA    #4
    BNE     SC_Next
    LDX     #VRAM_COL                   ; 2e plan : les couleurs
    BRA     SC_Next
    ENDC
SC_End:
    RTS


; ===================================================================
; SON
;   Partition : FDB voix1,voix2 / FCB durée (trames, la ligne dure durée+1) ...
;               FDB SN_END. Note = 1843200 / (2 x fréquence) ; SN_SIL = silence.
;   Le séquenceur (handler IRQ) lit la partition A CHAQUE IRQ, dans la page alors
;   mappée : on n'envoie donc jamais de son pendant un changement de page
;   (Snd_Wait avant FS_LoadFile / loadandexec) et on coupe le séquenceur
;   (Snd_Stop) quand un programme ou OSM-VISION lui-même s'en va.
;   Les Snd_xxx préservent A, B et X.
;   Le declencheur lui-meme (Snd_Start, IRQ masquees pour la bascule
;   pointeur+minuteur) est la source unique lib/snd.asm.
; ===================================================================
Snd_Tick:   PSHS    A,X
            LDX     #Sd_Tick
            LBRA    Snd_Go
Snd_Back:   PSHS    A,X
            LDX     #Sd_Back
            LBRA    Snd_Go
Snd_Select: PSHS    A,X
            LDX     #Sd_Select
            LBRA    Snd_Go
Snd_Ok:     PSHS    A,X
            LDX     #Sd_Ok
            LBRA    Snd_Go
Snd_Del:    PSHS    A,X
            LDX     #Sd_Del
            LBRA    Snd_Go
Snd_Boot:   PSHS    A,X
            LDX     #Sd_Boot
            LBRA    Snd_Go

; Attend la fin du son en cours (1,5 s au plus)
Snd_Wait:
    PSHS    D
    PSHSW
    LDB     #90
SW_Loop:
    LDA     SND_PTR
    ORA     SND_PTR+1
    BEQ     SW_Done                     ; 0 = séquenceur arrêté
    PSHS    B
    LDE     #1
    JSR     [table_function_ram+sys_video_wait_vsync]
    PULS    B
    DECB
    BNE     SW_Loop
SW_Done:
    PULSW
    PULS    D,PC

; ===================================================================
; AIDE (touche ?) : les raccourcis dans un panneau à droite du bureau,
; hors de la fenêtre des fichiers (colonnes 10-49) et du menu (26-47). Il
; reste ouvert (AideOn) jusqu'au ? suivant et revient après chaque
; redessin du bureau (Aide_Si) ; un dialogue posé dessus le sauve et le
; rend avec ce qu'il recouvre (Rect_Save / Rect_Restore).
; ===================================================================
AIDE_X          equ 52
AIDE_Y          equ 4
AIDE_W          equ 27
AIDE_H          equ 19

Aide_Bascule:
    LDA     AideOn
    EORA    #1
    STA     AideOn
    BEQ     AB_Ferme
    JSR     Aide_Dessine
    LBRA    Event_Loop
AB_Ferme:
    JSR     Aide_Efface
    LBRA    Event_Loop

; Redessine le panneau s'il est ouvert (après Draw_Base_UI).
Aide_Si:
    TST     AideOn
    BNE     Aide_Dessine
    RTS

Aide_Dessine:
    JSR     Sync_Begin
    LDA     #AIDE_X
    LDB     #AIDE_Y
    LDW     #(AIDE_W*256)+AIDE_H
    LDY     #Txt_AideTitre
    JSR     Draw_Window
    JSR     Sync_End
    JSR     Sync_Begin
    LDA     #COLOR_TEXT
    STA     TextAttr
    LDX     #Txt_Aide
    LDB     #AIDE_Y+2
AD_Ligne:
    TST     ,X                          ; une chaîne vide : la fin du texte
    BEQ     AD_Fin
    PSHS    B
    LDA     #AIDE_X+2
    JSR     Put_Text                    ; X passe à la ligne suivante
    PULS    B
    INCB
    BRA     AD_Ligne
AD_Fin:
    JSR     Sync_End
    RTS

; Rend le bureau sous le panneau (ombre comprise : une colonne et une
; rangée de plus).
Aide_Efface:
    JSR     Sync_Begin
    LDB     #AIDE_Y
AE_Rang:
    PSHS    B
    LDA     #AIDE_X
    JSR     Calc_Addr                   ; Y = première case de la rangée
    LDA     #UI_DESKTOP_PAT
    LDB     #COLOR_DESK
    LDE     #AIDE_W+1
AE_Case:
    STA     ,Y
    STB     VRAM_COL_OFS,Y
    LEAY    VRAM_PAS,Y
    DECE
    BNE     AE_Case
    PULS    B
    INCB
    CMPB    #AIDE_Y+AIDE_H+1
    BNE     AE_Rang
    JSR     Sync_End
    RTS

Txt_AideTitre:  FCN " Raccourcis "
Txt_Aide:
    FCN     "Haut, Bas   choisir"
    FCN     "Gauche, Dr. page"
    FCN     "Debut, Fin  1er, dernier"
    FCN     "Entree      ouvrir"
    FCN     "Espace      menu"
    FCN     "Tab         commande"
    FCN     "Ctrl+C      copier"
    FCN     "Ctrl+X      couper"
    FCN     "Ctrl+V      coller"
    FCN     "Ctrl+N      dossier"
    FCN     "Suppr       supprimer"
    FCN     "T           Terminal"
    FCN     "M           son oui/non"
    FCN     "?           cette aide"
    FCN     "Echap       quitter"
    FCB     0

; Touche M : son oui / non
Snd_Toggle:
    LDA     son_coupe
    CMPA    #SND_MUTED
    BNE     STG_Mute
    CLR     son_coupe                   ; son rétabli
    JSR     Snd_Tick
    BRA     STG_Show
STG_Mute:
    JSR     Snd_Stop
    LDA     #SND_MUTED
    STA     son_coupe
STG_Show:
    JSR     Sync_Begin
    JSR     Draw_Status
    JSR     Sync_End
    LBRA    Event_Loop


Sd_Tick:                                ; navigation : un tic aigu très court
    FDB     SN_E6,SN_SIL
    FCB     0
    FDB     SN_END
Sd_Back:                                ; annulation / fermeture
    FDB     SN_G4,SN_SIL
    FCB     1
    FDB     SN_END
Sd_Select:                              ; lancement : deux notes montantes
    FDB     SN_C5,SN_SIL
    FCB     1
    FDB     SN_G5,SN_SIL
    FCB     2
    FDB     SN_END
Sd_Ok:                                  ; réussite : petit arpège avec accord final
    FDB     SN_C5,SN_C4
    FCB     2
    FDB     SN_E5,SN_C4
    FCB     2
    FDB     SN_G5,SN_C5
    FCB     6
    FDB     SN_END
Sd_Del:                                 ; suppression : gamme descendante
    FDB     SN_E5,SN_SIL
    FCB     2
    FDB     SN_C5,SN_SIL
    FCB     2
    FDB     SN_G4,SN_SIL
    FCB     2
    FDB     SN_C4,SN_C3
    FCB     6
    FDB     SN_END
Sd_Boot:                                ; démarrage : "ta-da-daaa" sur deux voix
    FDB     SN_C5,SN_C4
    FCB     3
    FDB     SN_E5,SN_C4
    FCB     3
    FDB     SN_G5,SN_C4
    FCB     3
    FDB     SN_C6,SN_C5
    FCB     16
    FDB     SN_END

Load_Directory:
    CLR     FileCount
    CLR     Selection
    CLR     TopIndex
    CLR     Truncated
    LDX     #FileNames
    ; hors de la racine : ".." en tête
    LDD     #$FFFF
    JSR     [table_function_ram+sys_FS_Dossier]
    CMPD    #0
    BEQ     LD_Racine
    LDD     #$2E2E              ; ".."
    STD     ,X++
    LDB     #13
    LDA     #$20
LD_Blancs:
    STA     ,X+
    DECB
    BNE     LD_Blancs
    LDA     #FL_DIR+FL_PARENT
    STA     ,X+
    INC     FileCount
LD_Racine:
    PSHS    X

    ; CORRECTION VITALE : X doit pointer sur le buffer de sortie !
    LDX     #g_find_fileInfo
    JSR     [table_function_ram+sys_FS_FindFirst]
    BCS     Load_Dir_End
Load_Dir_Loop:
    LDA     g_find_fileInfo
    CMPA    #$01
    BNE     Load_Dir_Next

    LDX     #g_find_fileInfo+1
    LDY     0,S
    LDW     #15
    TFM     X+,Y+
    CLRA                        ; drapeaux : dossier ?
    LDB     g_find_fileInfo+27
    BITB    #$20
    BEQ     LD_Fl
    LDA     #FL_DIR
LD_Fl:
    STA     ,Y+
    STY     0,S

    INC     FileCount
    LDA     FileCount
    CMPA    #MAX_FILES
    BLO     Load_Dir_Next
    ; Buffer plein : reste-t-il encore des fichiers ? (affiché avec un '+')
    LDX     #g_find_fileInfo
    JSR     [table_function_ram+sys_FS_FindNext]
    BCS     Load_Dir_End
    INC     Truncated
    BRA     Load_Dir_End
Load_Dir_Next:
    ; CORRECTION VITALE : X doit pointer sur le buffer de sortie !
    LDX     #g_find_fileInfo
    JSR     [table_function_ram+sys_FS_FindNext]
    BCC     Load_Dir_Loop
Load_Dir_End:
    PULS    X
    IFNE    SORT_ENABLED
    JMP     Sort_Files          ; trie la liste, puis RTS
    ELSE
    RTS
    ENDC

; Tri alphabétique (insertion, stable) des noms de FileNames.
; Les noms sont complétés d'espaces : "CP" passe avant "CPU", puis '.', chiffres, lettres.
; Le reste des informations est relu par FS_FindEntry quand on en a besoin.
Sort_Files:
    LDA     FileCount
    CMPA    #2
    BLO     SF_End
    LDA     #1
    STA     SortI
SF_Outer:
    LDA     SortI               ; U = &a[i]
    LDB     #REC
    MUL
    LDX     #FileNames
    LEAU    D,X
    TFR     U,X                 ; SortTmp = a[i]
    LDY     #SortTmp
    LDW     #REC
    TFM     X+,Y+
SF_Inner:
    CMPU    #FileNames          ; trou en tête de liste : on place
    BLS     SF_Place
    LEAX    -REC,U              ; X = a[j], le candidat précédent
    ; d'abord les drapeaux : ".." puis les dossiers, puis les fichiers
    LDA     15,X
    CMPA    SortTmp+15
    BEQ     SF_Noms
    BHI     SF_Place            ; a[j] passe avant tmp
    BRA     SF_Decale
SF_Noms:
    LDY     #SortTmp
    LDB     #15
SF_Cmp:
    LDA     ,X+
    CMPA    ,Y+
    BNE     SF_Diff
    DECB
    BNE     SF_Cmp
    BRA     SF_Place            ; égal : on garde l'ordre
SF_Diff:
    BLO     SF_Place            ; a[j] < tmp : bonne place
SF_Decale:
    LEAX    -REC,U              ; a[j] > tmp : on le décale d'un cran
    TFR     U,Y
    LDW     #REC
    TFM     X+,Y+
    LEAU    -REC,U
    BRA     SF_Inner
SF_Place:
    LDX     #SortTmp
    TFR     U,Y
    LDW     #REC
    TFM     X+,Y+
    INC     SortI
    LDA     SortI
    CMPA    FileCount
    BLO     SF_Outer
SF_End:
    RTS

; Dessine VISIBLE_ROWS lignes à partir de TopIndex.
; Pas de variables sur la pile : U = pointeur sur le nom courant.
Draw_FileList:
    PSHS    CC,U
    ORCC    #%00010000          ; IRQ masquées pendant l'écriture VRAM

    LDA     FileCount
    LBEQ    Draw_FileList_End

    SUBA    TopIndex            ; nombre de lignes à dessiner
    CMPA    #VISIBLE_ROWS
    BLS     DFL_RowsOk
    LDA     #VISIBLE_ROWS
DFL_RowsOk:
    STA     DrawRows

    LDA     Selection           ; ligne de la sélection dans la fenêtre
    SUBA    TopIndex
    STA     DrawSel

    LDA     TopIndex            ; U = FileNames + TopIndex*REC
    LDB     #REC
    MUL
    ADDD    #FileNames
    TFR     D,U

    CLR     DrawRow

DFL_Loop:
    LDB     DrawRow             ; Y = VRAM_BASE + (ligne+7)*80 + 12
    ADDB    #7
    LDA     #VRAM_LIGNE
    MUL
    ADDD    #VRAM_BASE+12*VRAM_PAS
    TFR     D,Y

    LDD     #(ICO_FILE_L*256)+ICO_FILE_R
    TST     15,U
    BEQ     DFL_Ico
    LDD     #(ICO_DIR_L*256)+ICO_DIR_R
DFL_Ico:
    IFNE    CARTE_MONO
    STA     ,Y                  ; mono : les deux cases de l'icône
    STB     VRAM_PAS,Y
    LEAY    3*VRAM_PAS,Y
    LDB     #15                 ; les 15 caractères du nom
DFL_Car:
    LDA     ,U+
    STA     ,Y++
    DECB
    BNE     DFL_Car
    ELSE
    STD     ,Y

    LEAY    3,Y
    LDW     #15
    TFM     U+,Y+
    ENDC
    LEAU    1,U                 ; les drapeaux

    LEAY    VRAM_COL_OFS-18*VRAM_PAS,Y   ; début de la ligne, plan couleurs
    LDA     #COLOR_ICON
    STA     ,Y
    STA     VRAM_PAS,Y
    LDA     #COLOR_WIN
    STA     2*VRAM_PAS,Y

    LDA     DrawRow
    CMPA    DrawSel
    BNE     DFL_NotSel
    LDA     #COLOR_SEL
    BRA     DFL_SetColor
DFL_NotSel:
    LDA     #COLOR_TEXT
DFL_SetColor:
    LEAY    3*VRAM_PAS,Y
    IFNE    CARTE_MONO
    LDB     #15                 ; mono : une couleur sur deux octets
DFL_Coul:
    STA     ,Y++
    DECB
    BNE     DFL_Coul
    ELSE
    LDW     #15
    STA     FillByte
    LDD     #FillByte
    TFM     D,Y+
    ENDC

    INC     DrawRow
    LDA     DrawRow
    CMPA    DrawRows
    BLO     DFL_Loop

    BSR     Draw_Status

Draw_FileList_End:
    PULS    CC,U
    RTS

; Flèches de défilement + "sélection/total" (plan caractères)
Draw_Status:

    LDA     #UI_SPACE
    LDB     TopIndex
    BEQ     DS_NoUp
    LDA     #ARROW_UP
DS_NoUp:
    STA     UPMARK_POS

    LDA     #UI_SPACE
    LDB     TopIndex
    ADDB    #VISIBLE_ROWS
    CMPB    FileCount
    BHS     DS_NoDn
    LDA     #ARROW_DN
DS_NoDn:
    STA     DNMARK_POS

    IFNE    CARTE_MONO
    LDY     #TmpStr             ; mono : le texte d'abord en mémoire
    ELSE
    LDY     #STATUS_POS
    ENDC
    LDA     Selection
    INCA
    BSR     Put3
    LDA     #$2F                ; '/'
    STA     ,Y+
    LDA     FileCount
    BSR     Put3
    LDA     #ASCII_SPACE
    LDB     Truncated
    BEQ     DS_NoPlus
    LDA     #$2B                ; '+' : répertoire plus grand que MAX_FILES
DS_NoPlus:
    STA     ,Y+
    LDA     #ASCII_SPACE
    STA     ,Y+
    LDA     #UI_HP                      ; indicateur du son : le haut-parleur,
    STA     ,Y+                         ; avec ses ondes, ou barré (touche M)
    LDA     #UI_HP_ONDES
    LDB     son_coupe
    CMPB    #SND_MUTED
    BNE     DS_Snd
    LDA     #UI_HP_MUET
DS_Snd:
    STA     ,Y+
    LDA     #ASCII_SPACE
    STA     ,Y+
    STA     ,Y+

    ; Le texte du statut est en page 0 du générateur (ASCII) : attribut bit 7 = 0.
    ; Les cases de la fenêtre sont en $8F (page 1), il faut donc les recolorer.
    ; (Les flèches $42/$43 gardent COLOR_WIN, bit 7 = 1 -> page 1.)
    IFNE    CARTE_MONO
    LDX     #TmpStr             ; mono : les 13 cases, caractère et couleur
    LDY     #STATUS_POS
    LDB     #COLOR_TEXT
    LDE     #13
DS_Case:
    LDA     ,X+
    STD     ,Y++
    DECE
    BNE     DS_Case
    LDA     #COLOR_TEXT|$80             ; l'icône du son est en page 1
    STA     STATUS_POS+VRAM_COL_OFS+9*VRAM_PAS
    STA     STATUS_POS+VRAM_COL_OFS+10*VRAM_PAS
    LDA     #COLOR_TEXT                 ; sortie de la v4 : A = attribut, B = 0
    CLRB
    RTS
    ELSE
    LDX     #STATUS_POS+VRAM_COL_OFS
    LDA     #COLOR_TEXT
    LDW     #13
    STA     FillByte
    LDD     #FillByte
    TFM     D,X+
    LDA     #COLOR_TEXT|$80             ; l'icône du son est en page 1
    STA     STATUS_POS+VRAM_COL_OFS+9
    STA     STATUS_POS+VRAM_COL_OFS+10
    LDA     FillByte                    ; sortie identique a l'ancienne boucle : A = octet, B = 0
    CLRB
    RTS
    ENDC

; A (0..255) -> 3 caractères à ,Y+ (zéros de tête remplacés par des espaces)
Put3:
    CLR     NumStarted
    LDB     #ASCII_0
Put3_100:
    CMPA    #100
    BLO     Put3_100_Done
    SUBA    #100
    INCB
    BRA     Put3_100
Put3_100_Done:
    BSR     Put3_Digit
    LDB     #ASCII_0
Put3_10:
    CMPA    #10
    BLO     Put3_10_Done
    SUBA    #10
    INCB
    BRA     Put3_10
Put3_10_Done:
    BSR     Put3_Digit
    ADDA    #ASCII_0            ; unités : toujours affichées
    STA     ,Y+
    RTS

Put3_Digit:                     ; B = chiffre ASCII
    CMPB    #ASCII_0
    BNE     P3D_Show
    TST     NumStarted
    BNE     P3D_Show
    LDB     #ASCII_SPACE        ; zéro de tête -> espace (page 0)
    STB     ,Y+
    RTS
P3D_Show:
    STB     ,Y+
    INC     NumStarted
    RTS

Draw_Base_UI:
    ORCC    #%00010000

    CLRA                        ; page vidéo 0
    STA     VRAM_CTRL
    LDX     #VRAM_BASE
    IFNE    CARTE_MONO
    LDD     #(UI_DESKTOP_PAT*256)+COLOR_DESK    ; mono : motif et couleur, case par case
DBU_Case:
    STD     ,X++
    CMPX    #VRAM_END
    BNE     DBU_Case
    ELSE
    LDA     #UI_DESKTOP_PAT
    LDW     #VRAM_END-VRAM_BASE
    STA     FillByte
    LDD     #FillByte
    TFM     D,X+

    LDX     #VRAM_COL
    LDA     #COLOR_DESK
    LDW     #VRAM_END-VRAM_BASE
    STA     FillByte
    LDD     #FillByte
    TFM     D,X+
    ENDC

    LDA     #1                  ; pas d'attente VSYNC dans cette fenêtre-là
    STA     NoYield
    LDA     #10
    LDB     #5
    LDW     #$2814
    LDY     #TitleMsg
    JSR     Draw_Window
    CLR     NoYield

    ANDCC   #%11101111
    RTS

TitleMsg:       FCN " OSM-VISION "

; --- Variables de l'Explorateur (Placées directement à la fin du binaire) ---
FileCount       rmb 1           ; nombre de fichiers chargés (<= MAX_FILES)
Selection       rmb 1           ; index absolu du fichier sélectionné
TopIndex        rmb 1           ; index du premier fichier visible
OldSel          rmb 1           ; Selection avant la touche
OldTop          rmb 1           ; TopIndex avant la touche
MenuSel         rmb 1           ; entrée du menu contextuel
MenuX           rmb 1
MenuY           rmb 1
MenuI           rmb 1
MenuJ           rmb 1
BootSnd         rmb 1           ; <>0 : jouer le jingle de démarrage
AideOn          rmb 1           ; 1 : panneau des raccourcis ouvert (touche ?)
DigitCnt        rmb 1
TmpAttr         rmb 1
SaveSel         rmb 1
SaveTop         rmb 1
ViewTop         rmb 2           ; première ligne affichée
ViewOld         rmb 2
ViewSize        rmb 2           ; taille du fichier (<= $8000)
ViewRows        rmb 2           ; nombre de lignes dans le mode courant
ViewLine        rmb 2
ViewPos         rmb 2
LineCnt         rmb 2
ChunkLen        rmb 2
ScanOff         rmb 2
LTPtr           rmb 2
VBPtr           rmb 2
ViewMode        rmb 1           ; 0 = texte, 1 = hexa
ViewI           rmb 1
ViewJ           rmb 1
ColorByte       rmb 1
SpaceByte       rmb 1
LineTmp         rmb 80
ScreenSave      rmb 4000        ; 2 plans de l'écran pendant une application fenêtrée
ChunkBuf        equ ScreenSave                  ; Voir et les applications ne tournent jamais ensemble :
ViewBuf         equ ScreenSave+256              ; on recouvre les tampons (256+1368+2048 <= 4000)
LineTbl         equ ScreenSave+256+VIEW_COLS*VIEW_ROWS
AppEntry        rmb 2
AppPage         rmb 1           ; page de l'application lancée
AppRan          rmb 1
ScrDir          rmb 1
ScrCnt          rmb 1
RunPause        rmb 1           ; <>0 : attendre une touche après le programme
RunFenetre      rmb 1           ; <>0 : le programme tourne dans la fenêtre du Terminal
RunTitre        rmb 18          ; " NOM " de la fenêtre
CmdLen          rmb 1
SaveName        rmb 15          ; nom du fichier à retrouver après un rechargement
KeepPos         rmb 1           ; $A5 : Vision_Start doit restaurer la position
RP_Idx          rmb 1
SortI           rmb 1
SortTmp         rmb REC
RenBuf          rmb 16          ; saisie du nouveau nom
RenLen          rmb 1
NewName         rmb 15          ; nouveau nom, 15 octets complétés d'espaces
DlgTitle        rmb 2           ; Name_Dialog : titre de la boîte
DlgAction       rmb 2           ;               action sur NewName
InfoBuf         rmb 14          ; FS_FileInfo
ClipMode        rmb 1           ; presse-papiers : 0 vide, 1 copier, 2 couper
ClipName        rmb 15
ClipDir         rmb 2           ; n° du dossier d'origine
SrcName         rmb 16          ; le fichier d'origine, formaté avec son chemin
NomTmp          rmb 15
PathN           rmb 1
PathIds         rmb 2*PATH_NIV
PathBuf         rmb 16*PATH_NIV+20
AttrNew         rmb 1           ; attributs en cours d'édition
AttrOrig        rmb 1
AttrCur         rmb 1           ; case sélectionnée (0..4)
PropLock        rmb 1           ; <>0 : fichier protégé, attributs en lecture seule
PropI           rmb 1
PropMask        rmb 1
CmdBuf          rmb 80          ; ligne de commande (terminée par 0)
Truncated       rmb 1           ; <>0 : répertoire plus grand que MAX_FILES
DrawRow         rmb 1
DrawRows        rmb 1
DrawSel         rmb 1
NumStarted      rmb 1
FileNames       rmb MAX_FILES*REC
DirBuf          rmb 16              ; nom du dossier où entrer (NUL final)
