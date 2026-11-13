; ===================================================================
; MINITEL.ASM - Minitel d'OSM-VISION : terminal Vidéotex par la liaison série
; ===================================================================
; La carte joue le Minitel. Le modem, à 115200 bauds sur la liaison
; série : un vrai modem V.23 (Olitec Speed'Com 2000, essayé le 27 oct.
; 2026) qui appelle MiniPavi au 09 72 10 17 21, ou tools/minitel/modem.py
; sur le PC, qui relie la carte aux serveurs Minitel d'Internet.
;
; 1. Un numéro est demandé (3615 par défaut ; 0 = page d'essai de
;    modem.py). « 36xx » (4 chiffres) devient le numéro de MiniPavi.
; 2. La liaison série passe en MODE BRUT du BIOS (serie_brute : les octets
;    reçus vont dans l'anneau serie_buf, sans écho ni Ctrl+A), puis
;    « ATE0&D0B2M1S91=6DT<numéro> » part ; on attend CONNECT, NO CARRIER...
;    E0 sans écho, &D0 DTR ignoré (la carte n'a pas de DTR : broches 4-6
;    bouclées), B2 V.23 (1200/75), M1 haut-parleur coupé à la connexion.
;    MiniPavi répond par un message vocal (« tapez 1 ... sinon
;    Connexion/Fin ») : quatre virgules (2 s chacune) le laissent passer
;    avant que le modem lance sa porteuse.
; 3'. Les touches partent en 7 bits + parité paire (Envoie_P), comme un
;    Minitel ; ce qui arrive perd son bit 7 (Vt_Octet).
; 3. En ligne, chaque octet reçu passe au décodeur Vidéotex (Vt_Octet),
;    qui écrit dans l'écran LOGIQUE du Minitel (LG/LT/LA : 40 x 25 cases,
;    code, genre, attribut) et marque la rangée ; à chaque trame, Rendu
;    convertit quelques rangées marquées (hors retour de trame) puis les
;    recopie dans la VRAM (480 octets au plus : le budget d'une trame).
; 4. Échap raccroche (« +++ » encadré d'une seconde de silence, puis
;    ATH) ; « NO CARRIER » dans le flux : le serveur a raccroché.
;
; Le décodeur est le MODÈLE tools/minitel/videotex.py traduit règle
; pour règle : test/verifie_minitel.py prouve que les deux donnent le
; même écran, octet pour octet. Changer une règle ici, c'est la changer
; là-bas aussi. Tables (couleurs, accents) : apps/minitel_data.inc,
; générées par le modèle ; glyphes des mosaïques : page 1 $50-$5D.
;
; Deux affichages (Ctrl+F bascule), tirés du même écran logique :
;   Mode 0, FENÊTRE : 40 x 25 dans une fenêtre d'OSM-VISION (colonnes
;     19-60, rangées 0-26 : le moniteur montre 30 rangées) ; une case =
;     une cellule, mosaïque -> Tab_Mos40 (disjoint dessiné contigu) ;
;   Mode 1, PLEIN ÉCRAN : une case = deux cellules (80 x 25, proportions
;     d'un Minitel) ; mosaïque -> deux colonnes de 3 pavés.
; Rangées 27-29 : la barre des touches. Les rangées 25-29 sont sauvées au
; départ et rendues à la sortie (OSM-VISION ne garde que 0-24) ; l'écran
; d'OSM-VISION (0-24) est sauvé pour redessiner le bureau en mode fenêtre.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"
    include "../lib/ui.inc"
    include "../lib/vis.inc"

    export App_Start

LIGNES          equ 25          ; rangées Minitel (0 = ligne de service)
NCOL            equ 40          ; colonnes Minitel
ATT_DEFAUT      equ $0F         ; blanc clair sur noir (Ecran.__init__)
SAUVE_RANG      equ 25          ; rangées 25-29 : sauvées, rendues à la sortie
SAUVE_OCTETS    equ 400         ; 5 rangées x 80 (un plan)
BARRE           equ 27          ; barre des touches : rangées 27, 28, statut 29
COUL_BARRE      equ COLOR_SEL   ; blanc sur bleu, page 0
RENDU_40        equ 6           ; rangées par trame en fenêtre (6 x 80 octets)
RENDU_80        equ 3           ; en plein écran (3 x 160 octets)
RB_ATT          equ RENDU_40*80 ; tampon de rendu : caractères, puis attributs
NUM_MAX         equ 30          ; longueur maximale du numéro
FEN_X           equ 19          ; fenêtre du Minitel (cadre compris)
FEN_Y           equ 0
FEN_W           equ 42
FEN_H           equ 27
ZONE_X          equ FEN_X+1     ; case (0, 0) du Minitel à l'écran
ZONE_Y          equ FEN_Y+1
DLG_X           equ 18          ; boîte du numéro
DLG_Y           equ 8
DLG_W           equ 44
DLG_H           equ 8
ATTENTE_APPEL   equ 1800        ; trames (30 s) avant « pas de réponse »
GARDE           equ 90          ; trames (1,5 s) de silence autour de +++ (le modem veut 1 s)
; ACIA 68B50 sur E = 1,8432 MHz : ÷16 = 115200 bauds, la seule vitesse
; standard qu'il sache faire (÷64 = 28800 n'en est pas une : un vrai modem
; ne la reconnaît pas). Les octets arrivent quand même au rythme de la
; ligne (~120 octets/s) : le modem, ou modem.py, les dose.
ACIA_115200     equ $95         ; NMI en réception, RTS=0, 8N1, horloge/16

    section .code

; -------------------------------------------------------------------
; POINT D'ENTRÉE (offset 0). IRQ actives à l'entrée.
; -------------------------------------------------------------------
App_Start:
    LDA     #1                  ; mode brut : plus rien ne va au tampon de ligne
    STA     serie_brute
    LDA     #ACIA_115200
    STA     CR_reg
    JSR     Vide_Anneau
    JSR     Sauve_Barre
    JSR     [VIS_TABLE+vis_Sync_Begin]
    CLRA                        ; l'écran d'OSM-VISION, pour le mode fenêtre
    CLRB
    LDW     #(80*256)+LIGNES
    LDX     #EcranOSM
    JSR     [VIS_TABLE+vis_Rect_Save]
    JSR     [VIS_TABLE+vis_Sync_End]
    CLR     Mode                ; fenêtre
    JSR     Vt_Init
    JSR     Cadre

; --- 1. Le numéro (la boîte rend ce qu'elle a couvert) ---
Dialogue:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    BSR     Dlg_Regs
    JSR     [VIS_TABLE+vis_Rect_Save]
    LDA     #DLG_X
    LDB     #DLG_Y
    LDW     #(DLG_W*256)+DLG_H
    LDY     #Txt_Titre
    JSR     [VIS_TABLE+vis_Window]
    LDU     #Textes_Dialogue
Dl_Txt:
    LDA     ,U+
    BEQ     Dl_Fin
    LDB     ,U+
    LDX     ,U++
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]  ; préserve U
    BRA     Dl_Txt
Dl_Fin:
    JSR     [VIS_TABLE+vis_Sync_End]
    LDX     #Txt_Pret
    JSR     Statut
    LDA     #DLG_X+12
    LDB     #DLG_Y+2
    LDX     #NumBuf
    LDE     #NUM_MAX
    LDF     #INP_NON_VIDE
    LDY     #0
    JSR     [VIS_TABLE+vis_Input]
    PSHS    CC                  ; C = 1 : Échap
    JSR     [VIS_TABLE+vis_Sync_Begin]
    BSR     Dlg_Regs
    JSR     [VIS_TABLE+vis_Rect_Restore]
    JSR     [VIS_TABLE+vis_Sync_End]
    PULS    CC
    LBCS    Quitter             ; Échap : retour à OSM-VISION
    BRA     Appel

Dlg_Regs:                       ; rectangle de la boîte, ombre comprise
    LDA     #DLG_X
    LDB     #DLG_Y
    LDW     #((DLG_W+1)*256)+DLG_H+1
    LDX     #DlgSauve
    RTS

; --- 2. L'appel ---
Appel:
    LDX     #Txt_Appel
    JSR     Statut
    JSR     Vide_Anneau
    LDX     #Cmd_Appel          ; CR (ligne vide), puis ATE0&D0B2M1S91=6DT
    JSR     Envoie_ChaineP      ; avec parité, comme les touches : le modem
                                ; répond dans la parité qu'il a reçue
    LDX     #NumBuf
    LDD     ,X                  ; « 36xx » : le numéro de MiniPavi
    CMPD    #$3336
    BNE     Ap_Num
    TST     4,X
    BNE     Ap_Num
    LDX     #Num_MiniPavi
Ap_Num:
    JSR     Envoie_ChaineP
    LDA     #$0D
    JSR     Envoie_P
    CLR     LigLen
    LDW     #ATTENTE_APPEL
    STW     Compte
Ap_Boucle:
    JSR     Rendu               ; une trame
    LDW     Compte
    DECW
    STW     Compte
    BEQ     Ap_Muet
Ap_Lit:
    JSR     Lit_Serie
    BCS     Ap_Clavier
    ANDA    #$7F                ; réponses en 7 bits + parité (celle de l'AT)
    JSR     Ligne_Modem         ; C = 1 : une ligne complète dans LigBuf
    BCC     Ap_Lit
    LDX     #LigBuf
    LDY     #Rep_Connect
    JSR     Prefixe
    LBEQ    En_Ligne
    LDY     #Mots_Echec
Ap_Echec:
    TST     ,Y
    BEQ     Ap_Lit              ; une autre ligne (écho...) : on l'ignore
    JSR     Prefixe             ; préserve X ; Y -> mot suivant
    BNE     Ap_Echec
    LDX     #LigBuf             ; NO CARRIER, BUSY... : le modem a dit non
    BRA     Ap_Message
Ap_Clavier:
    JSR     [table_function_ram+sys_kbd_poll]
    TSTA
    LBEQ    Ap_Boucle
    CMPA    #$1B
    BNE     Ap_Boucle
    LDX     #Cmd_ATH            ; Échap : abandon
    JSR     Envoie_ChaineP
    LBRA    Dialogue
Ap_Muet:
    LDX     #Txt_Muet
Ap_Message:
    LDY     #Txt_TitreAppel
    JSR     [VIS_TABLE+vis_MsgBox]
    LBRA    Dialogue

; --- 3. En ligne ---
En_Ligne:
    JSR     Vt_Init             ; écran du Minitel vierge
    LDA     #1
    STA     AffCurseur          ; le curseur du Minitel (CON/COFF) s'affiche
    LDX     #Txt_EnLigne
    JSR     Statut
    CLR     NcIdx
EL_Boucle:
    JSR     Rendu
    JSR     Pce_Garde           ; NACK resté sans réponse : on le renvoie
EL_Lit:
    JSR     Lit_Serie
    BCS     EL_Clavier
    STA     Recu
    JSR     Term_Octet          ; PCE, réponses au serveur, puis l'écran
    LDA     Recu
    ANDA    #$7F                ; le modem parle avec la parité de l'appel
    JSR     Guette_NC
    BCS     EL_Fin
    JSR     [table_function_ram+sys_kbd_poll]   ; le clavier entre deux octets
    TSTA
    BEQ     EL_Lit
    BRA     EL_Clef
EL_Fin:
    CLR     AffCurseur
    JSR     Rendu_Tout          ; le serveur a raccroché
    LDX     #Txt_Fin
    JSR     Statut
    LDX     #Txt_Raccroche
    LDY     #Txt_TitreAppel
    JSR     [VIS_TABLE+vis_MsgBox]
    LBRA    Dialogue
; Clavier : sys_kbd_poll (BIOS) ne bloque jamais ; la file du BIOS garde
; les codes PS/2 arrivés pendant une trame ou un décodage.
EL_Clavier:
    JSR     [table_function_ram+sys_kbd_poll]
    TSTA
    LBEQ    EL_Boucle
EL_Clef:
    CMPA    #$1B
    BEQ     Raccroche
    CMPA    #$06                ; Ctrl+F : fenêtre <-> plein écran
    BEQ     Bascule
    JSR     Touche
    BRA     EL_Boucle
Bascule:
    LDA     Mode
    EORA    #1
    STA     Mode
    JSR     Cadre
    LBRA    EL_Boucle

; --- 4. Raccrocher : silence, +++, silence, ATH ---
Raccroche:
    CLR     AffCurseur
    LDX     #Txt_Raccrochage
    JSR     Statut
    JSR     Garde
    LDX     #Cmd_Plus
    JSR     Envoie_Chaine
    JSR     Garde
    LDX     #Cmd_ATH
    JSR     Envoie_ChaineP
    JSR     Garde               ; « OK » du modem, jeté
    LBRA    Dialogue

Quitter:
    CLR     AffCurseur          ; curseur caché (le bureau d'OSM-VISION)
    JSR     Rendu
    LDA     #ACIA_115200        ; la liaison série revient à la console
    STA     CR_reg
    CLR     serie_brute
    JSR     Rend_Barre
    RTS                         ; OSM-VISION restaure les rangées 0-24

; GARDE trames sans rien envoyer ; ce qui arrive est jeté, l'écran suit.
Garde:
    LDW     #GARDE
    STW     Compte
Gd_Boucle:
    JSR     Rendu
    JSR     Vide_Anneau
    LDW     Compte
    DECW
    STW     Compte
    BNE     Gd_Boucle
    RTS

; -------------------------------------------------------------------
; Clavier -> serveur. A = code de scan_keyboard.
; -------------------------------------------------------------------
Touche:
    LDX     #Tab_Fonctions      ; touches de fonction : SEP + lettre
Tc_Fn:
    LDB     ,X
    BEQ     Tc_Fleche
    CMPA    ,X++
    BNE     Tc_Fn
    LDA     #$13
    JSR     Envoie_P
    LDA     -1,X
    BRA     Envoie_P
Tc_Fleche:
    CMPA    #KEY_UP
    BLO     Tc_Accent
    CMPA    #KEY_RIGHT
    BHI     Tc_Accent
    SUBA    #KEY_UP-1           ; haut 1 -> A, bas -> B, gauche -> D, droite -> C
    LDX     #Tab_Fleches-1
    LDA     A,X
    PSHS    A
    LDA     #$1B
    JSR     Envoie_P
    LDA     #'['
    JSR     Envoie_P
    PULS    A
    BRA     Envoie_P
Tc_Accent:
    LDX     #Tab_Clavier        ; Latin-1 -> SS2 + diacritique (+ lettre)
Tc_Ac:
    LDB     ,X
    BEQ     Tc_Ascii
    CMPA    ,X
    BEQ     Tc_AcOk
    LEAX    3,X
    BRA     Tc_Ac
Tc_AcOk:
    LDA     #$19
    JSR     Envoie_P
    LDA     1,X
    JSR     Envoie_P
    LDA     2,X
    BNE     Envoie_P
    RTS
Tc_Ascii:
    CMPA    #$20
    BLO     Tc_Rien
    CMPA    #$7E
    BLS     Envoie_P
Tc_Rien:
    RTS

; -------------------------------------------------------------------
; Liaison série. Envoie : A -> TDR (attend que l'ACIA soit libre).
; Préserve tout sauf CC. Envoie_P : les 7 bits de A + parité paire au
; bit 7 (une touche vers le serveur) ; A en sort avec sa parité.
; -------------------------------------------------------------------
Envoie_P:
    PSHS    B
    ANDA    #$7F
    TFR     A,B
    LSRB                        ; B = a ^ a>>4 ^ a>>2... : parité au bit 0
    LSRB
    LSRB
    LSRB
    PSHS    A
    EORB    ,S
    STB     ,S
    LSRB
    LSRB
    EORB    ,S
    STB     ,S
    LSRB
    EORB    ,S+
    RORB                        ; C = 1 : nombre de 1 impair
    BCC     Ep_Pair
    ORA     #$80
Ep_Pair:
    PULS    B
Envoie:
    PSHS    B
Ev_Att:
    LDB     SR
    BITB    #$02                ; TDRE
    BEQ     Ev_Att
    STA     TDR
    PULS    B,PC

Envoie_Chaine:                  ; X = chaîne (0 final)
    LDA     ,X+
    BEQ     Ec_Fin
    BSR     Envoie
    BRA     Envoie_Chaine
Ec_Fin:
    RTS

; Lit_Serie : C = 1 si l'anneau est vide ; sinon C = 0, A = octet.
; Seul ce programme écrit serie_queue (la NMI écrit serie_tete).
Lit_Serie:
    LDB     serie_queue
    CMPB    serie_tete
    BEQ     Ls_Vide
    LDX     #serie_buf
    ABX
    LDA     ,X
    INCB
    STB     serie_queue
    ANDCC   #$FE
    RTS
Ls_Vide:
    ORCC    #$01
    RTS

Vide_Anneau:
    LDA     serie_tete
    STA     serie_queue
    RTS

; Ligne_Modem : A = octet reçu pendant l'appel. Les caractères visibles
; s'ajoutent à LigBuf ; CR ou LF termine une ligne non vide : C = 1.
Ligne_Modem:
    CMPA    #$20
    BLO     Lm_Fin
    LDB     LigLen
    CMPB    #23
    BHS     Lm_Non
    LDX     #LigBuf
    STA     B,X
    INCB
    STB     LigLen
    CLR     B,X
Lm_Non:
    ANDCC   #$FE
    RTS
Lm_Fin:
    TST     LigLen
    BEQ     Lm_Non
    CLR     LigLen
    ORCC    #$01
    RTS

; Prefixe : X = ligne, Y = mot (0 final). Z = 1 si la ligne commence par
; le mot. Préserve X ; Y pointe ensuite sur le mot suivant de la liste.
Prefixe:
    PSHS    X
    CLRB                        ; B = 0 : égal jusqu'ici
Px_Boucle:
    LDA     ,Y+
    BEQ     Px_Fin
    CMPA    ,X+
    BEQ     Px_Boucle
    INCB
    BRA     Px_Boucle           ; on va au bout du mot (liste de mots)
Px_Fin:
    PULS    X
    TSTB
    RTS

; Guette_NC : A = octet reçu en ligne. C = 1 quand « NO CARRIER » est
; passé en entier (le modem a perdu la porteuse).
Guette_NC:
    LDX     #Rep_NoCarrier
    LDB     NcIdx
    CMPA    B,X
    BEQ     Gn_Suite
    CLRB
    CMPA    ,X                  ; un 'N' peut recommencer le mot
    BNE     Gn_Pose
Gn_Suite:
    INCB
    TST     B,X
    BNE     Gn_Pose
    CLR     NcIdx
    ORCC    #$01
    RTS
Gn_Pose:
    STB     NcIdx
    ANDCC   #$FE
    RTS

; -------------------------------------------------------------------
; Affichage. Rendu : une trame. Au plus RENDU_40 (fenêtre) ou RENDU_80
; (plein écran) rangées marquées sont converties dans RbChr (caractères)
; et RbChr+RB_ATT (attributs), HORS du retour de trame, en partant de la
; rangée qui suit la dernière servie ; puis recopiées dans la VRAM.
; -------------------------------------------------------------------
Rendu:
    CLR     RbN
    LDA     #RENDU_40
    TST     Mode
    BEQ     Rd_Max
    LDA     #RENDU_80
Rd_Max:
    STA     RenduN
    LDA     #LIGNES
    STA     RenduTours
    LDB     RenduLig
Rd_Boucle:
    LDX     #Sale
    TST     B,X
    BEQ     Rd_Suiv
    CLR     B,X
    PSHS    B
    JSR     Conv_Rang
    PULS    B
    DEC     RenduN
    BEQ     Rd_Stop
Rd_Suiv:
    INCB
    CMPB    #LIGNES
    BLO     Rd_Tour
    CLRB
Rd_Tour:
    DEC     RenduTours
    BNE     Rd_Boucle
Rd_Stop:
    INCB
    CMPB    #LIGNES
    BLO     Rd_Fin
    CLRB
Rd_Fin:
    STB     RenduLig
    JSR     [VIS_TABLE+vis_Sync_Begin]
    JSR     Pose_Curseur        ; IRQ masquées : R10, et VRAM_PTR pour R14/R15
    CLR     RbK
Rd_Copie:
    LDA     RbK
    CMPA    RbN
    BHS     Rd_Vide
    LDX     #RbLig
    LDB     A,X                 ; rangée du Minitel
    TST     Mode
    BNE     Rd_80
    INCB                        ; fenêtre : rangée + ZONE_Y, colonne ZONE_X
    LDA     #VRAM_LIGNE
    MUL
    ADDD    #VRAM_BASE+ZONE_X*VRAM_PAS
    LDW     #NCOL
    BRA     Rd_Dest
Rd_80:
    LDA     #VRAM_LIGNE
    MUL
    ADDD    #VRAM_BASE
    LDW     #80
Rd_Dest:
    STD     RbDest
    STW     RbLarg
    TFR     D,Y
    LDA     #80
    LDB     RbK
    MUL
    ADDD    #RbChr
    TFR     D,X
    IFNE    CARTE_MONO
Rd_Cel:                         ; mono : caractère puis attribut, case par case
    LDA     ,X
    LDB     RB_ATT,X
    STD     ,Y++
    LEAX    1,X
    DECW
    BNE     Rd_Cel
    ELSE
    TFM     X+,Y+
    LEAX    RB_ATT,X            ; X a avancé de la largeur : attributs
    LDD     RbLarg
    NEGD
    LEAX    D,X
    LDY     RbDest
    LEAY    VRAM_COL_OFS,Y
    LDW     RbLarg
    TFM     X+,Y+
    ENDC
    INC     RbK
    BRA     Rd_Copie
Rd_Vide:
    JSR     [VIS_TABLE+vis_Sync_End]
    RTS

; Conv_Rang : B = rangée du Minitel -> tampon de rendu n° RbN (puis RbN+1).
Conv_Rang:
    LDX     #RbLig
    LDA     RbN
    STB     A,X
    LDA     #NCOL
    MUL
    ADDD    #LG
    TFR     D,X                 ; X = première case de la rangée
    LDA     #80
    LDB     RbN
    MUL
    ADDD    #RbChr
    TFR     D,Y
    INC     RbN
    LDE     #NCOL
    TST     Mode
    BNE     Cv_80
Cv_40:                          ; une case = une cellule
    LDA     ,X
    TST     LT-LG,X
    BEQ     Cv_40t
    LDU     #Tab_Mos40
    LDA     A,U                 ; valeur 0-63 : positive
Cv_40t:
    STA     ,Y
    LDA     LA-LG,X
    STA     RB_ATT,Y
    LEAX    1,X
    LEAY    1,Y
    DECE
    BNE     Cv_40
    RTS
Cv_80:                          ; une case = deux cellules
    LDA     LA-LG,X
    STA     RB_ATT,Y
    STA     RB_ATT+1,Y
    LDA     ,X
    LDB     LT-LG,X
    BNE     Cv_80m
    STA     ,Y                  ; lettre + espace
    LDA     #$20
    STA     1,Y
    BRA     Cv_80s
Cv_80m:
    CMPB    #1
    BEQ     Cv_80c
    LDB     #MOS_DISJ
    BRA     Cv_80b
Cv_80c:
    LDB     #MOS_CONT
Cv_80b:
    STB     BaseTmp
    BSR     Col_Gauche
    BSR     Cv_Glyphe
    STB     ,Y
    BSR     Col_Droite
    BSR     Cv_Glyphe
    STB     1,Y
Cv_80s:
    LEAX    1,X
    LEAY    2,Y
    DECE
    BNE     Cv_80
    RTS
Cv_Glyphe:                      ; B = numéro 0-7 -> 0 ou BaseTmp+B
    TSTB
    BEQ     Cg_Fin
    ADDB    BaseTmp
Cg_Fin:
    RTS
Col_Gauche:                     ; A = mosaïque -> B = pavés b0 b2 b4 (préserve A)
    CLRB
    BITA    #$01
    BEQ     Cl_G2
    ORB     #1
Cl_G2:
    BITA    #$04
    BEQ     Cl_G4
    ORB     #2
Cl_G4:
    BITA    #$10
    BEQ     Cl_GF
    ORB     #4
Cl_GF:
    RTS
Col_Droite:                     ; A = mosaïque -> B = pavés b1 b3 b5
    CLRB
    BITA    #$02
    BEQ     Cl_D3
    ORB     #1
Cl_D3:
    BITA    #$08
    BEQ     Cl_D5
    ORB     #2
Cl_D5:
    BITA    #$20
    BEQ     Cl_DF
    ORB     #4
Cl_DF:
    RTS

; Pose_Curseur : le curseur matériel sur la case (Lig, Col) du Minitel s'il
; est allumé (CON) et qu'on est en ligne, sinon caché. L'IRQ VSYNC du BIOS
; recopie VRAM_PTR dans R14/R15 à chaque trame. IRQ masquées (Sync).
Pose_Curseur:
    LDA     #CURSEUR_CACHE
    TST     AffCurseur
    BEQ     Pc_R10
    TST     Curseur
    BEQ     Pc_R10
    LDB     Lig
    TST     Mode
    BNE     Pc_80
    ADDB    #ZONE_Y             ; fenêtre : une cellule par case
    LDA     #VRAM_LIGNE
    MUL
    ADDB    Col
    ADCA    #0
    IFNE    CARTE_MONO          ; mono : 2 octets par cellule
    ADDB    Col
    ADCA    #0
    ENDC
    ADDD    #VRAM_BASE+ZONE_X*VRAM_PAS
    BRA     Pc_Pose
Pc_80:                          ; plein écran : deux cellules par case
    LDA     #VRAM_LIGNE
    MUL
    ADDB    Col
    ADCA    #0
    ADDB    Col
    ADCA    #0
    IFNE    CARTE_MONO
    ADDB    Col
    ADCA    #0
    ADDB    Col
    ADCA    #0
    ENDC
    ADDD    #VRAM_BASE
Pc_Pose:
    STD     VRAM_PTR
    LDA     #CURSEUR_VISIBLE
Pc_R10:
    PSHS    A
    LDA     #10
    STA     CRTC_RS
    PULS    A
    STA     CRTC_DATA
    RTS

; Rendu_Tout : jusqu'à ce que plus rien ne soit marqué.
Rendu_Tout:
    JSR     Rendu
    LDX     #Sale
    LDB     #LIGNES
Rt_Test:
    TST     ,X+
    BNE     Rendu_Tout
    DECB
    BNE     Rt_Test
    RTS

Tout_Sale:
    LDX     #Sale
    LDB     #LIGNES
    LDA     #1
Ts_Boucle:
    STA     ,X+
    DECB
    BNE     Ts_Boucle
    RTS

; Cadre : le décor du mode courant, puis la barre ; tout est à redessiner.
; Fenêtre : bureau d'OSM-VISION (sauvé au départ), rangées 25-26
; d'origine, la fenêtre. Plein écran : rangées 25-26 en couleur de barre.
Cadre:
    TST     Mode
    BNE     Cd_Plein
    JSR     [VIS_TABLE+vis_Sync_Begin]
    CLRA
    CLRB
    LDW     #(80*256)+LIGNES
    LDX     #EcranOSM
    JSR     [VIS_TABLE+vis_Rect_Restore]
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDX     #BarreSauve
    IFNE    CARTE_MONO
    LDY     #VRAM_BASE+(SAUVE_RANG*VRAM_LIGNE)    ; mono : 2 rangées entrelacées
    LDW     #2*VRAM_LIGNE
    TFM     X+,Y+
    ELSE
    LDY     #VRAM_BASE+(SAUVE_RANG*80)
    LDW     #160
    TFM     X+,Y+
    LDX     #BarreSauve+SAUVE_OCTETS
    LDY     #VRAM_COL+(SAUVE_RANG*80)
    LDW     #160
    TFM     X+,Y+
    ENDC
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #FEN_X
    LDB     #FEN_Y
    LDW     #(FEN_W*256)+FEN_H
    LDY     #Txt_Titre
    JSR     [VIS_TABLE+vis_Window]
    JSR     [VIS_TABLE+vis_Sync_End]
    BRA     Cd_Fin
Cd_Plein:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    CLRA
    LDB     #LIGNES
    LDW     #(80*256)+2
    LDY     #($20*256)+COUL_BARRE
    JSR     [VIS_TABLE+vis_Fill]
    JSR     [VIS_TABLE+vis_Sync_End]
Cd_Fin:
    JSR     Tout_Sale
    LBRA    Dessine_Barre

; Rangées 25-29 : sauvées au départ, rendues à la sortie. Un plan par trame.
; v4 : un plan puis l'autre. mono : les 5 rangées entrelacées (800
; octets), en deux moitiés : SAUVE_OCTETS par trame dans les deux cas.
Sauve_Barre:
    LDX     #VRAM_BASE+(SAUVE_RANG*VRAM_LIGNE)
    LDY     #BarreSauve
    BSR     Copie_Barre
    IFNE    CARTE_MONO
    LDX     #VRAM_BASE+(SAUVE_RANG*VRAM_LIGNE)+SAUVE_OCTETS   ; la seconde moitié
    LDY     #BarreSauve+SAUVE_OCTETS
    BRA     Copie_Barre
    ELSE
    LDX     #VRAM_COL+(SAUVE_RANG*80)
    BRA     Copie_Barre
    ENDC
Rend_Barre:
    LDX     #BarreSauve
    LDY     #VRAM_BASE+(SAUVE_RANG*VRAM_LIGNE)
    BSR     Copie_Barre
    IFNE    CARTE_MONO
    LDX     #BarreSauve+SAUVE_OCTETS
    LDY     #VRAM_BASE+(SAUVE_RANG*VRAM_LIGNE)+SAUVE_OCTETS
    ELSE
    LDY     #VRAM_COL+(SAUVE_RANG*80)
    ENDC
Copie_Barre:                    ; X -> Y, SAUVE_OCTETS, dans une trame
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDW     #SAUVE_OCTETS
    TFM     X+,Y+
    JSR     [VIS_TABLE+vis_Sync_End]
    RTS

Dessine_Barre:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    CLRA
    LDB     #BARRE
    LDW     #(80*256)+3
    LDY     #($20*256)+COUL_BARRE
    JSR     [VIS_TABLE+vis_Fill]
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     [VIS_TABLE+vis_Sync_Begin]
    CLRA
    LDB     #BARRE
    LDX     #Txt_Touches1
    LDE     #COUL_BARRE
    JSR     [VIS_TABLE+vis_Text]
    CLRA
    LDB     #BARRE+1
    LDX     #Txt_Touches2
    LDE     #COUL_BARRE
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
    LDX     StatutCourant       ; la rangée de statut, redite
    BEQ     Db_Fin
    JSR     Statut
Db_Fin:
    RTS

; Statut : X = message, sur la rangée BARRE+2 (effacée d'abord).
Statut:
    STX     StatutCourant
    PSHS    X
    JSR     [VIS_TABLE+vis_Sync_Begin]
    CLRA
    LDB     #BARRE+2
    LDW     #(80*256)+1
    LDY     #($20*256)+COUL_BARRE
    JSR     [VIS_TABLE+vis_Fill]
    LDA     #1
    LDB     #BARRE+2
    LDX     ,S
    LDE     #COUL_BARRE
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
    PULS    X,PC

; ===================================================================
; DÉCODEUR VIDÉOTEX (modèle : tools/minitel/videotex.py, classe Ecran)
; ===================================================================
; Vt_Init : écran logique vierge (texte $20 / ATT_DEFAUT), rangée 1
; colonne 0, attributs par défaut, aucune séquence en cours ; tout marqué.
Vt_Init:
    LDX     #CstBlanc
    LDY     #LG
    LDW     #LIGNES*NCOL
    TFM     X,Y+
    LDX     #CstZero
    LDY     #LT
    LDW     #LIGNES*NCOL
    TFM     X,Y+
    LDX     #CstAttr
    LDY     #LA
    LDW     #LIGNES*NCOL
    TFM     X,Y+
    LDA     #1
    STA     Lig
    CLR     Col
    CLR     Etat
    CLR     Diac
    CLR     DerOk
    CLR     Curseur
    CLR     PceOn               ; couche terminal : sans PCE, rien en cours
    CLR     PceEtat
    CLR     PceDle
    CLR     PceAtt
    CLR     Hist
    CLR     Hist+1
    CLR     Hist+2
    CLR     BrutH
    CLR     BrutH+1
    CLR     BrutH+2
    JSR     Raz_Attributs
    LBRA    Tout_Sale

Raz_Attributs:
    LDA     #7
    STA     Fg
    CLR     Bg
    CLR     Inv
    CLR     Disj
    CLR     G1
    LDA     #1
    STA     Larg
    RTS

; ===================================================================
; COUCHE TERMINAL (modèle : classe Terminal de videotex.py) : réponses
; au serveur (START/STOP PROCEDURE, ENQROM, STATUS) et procédure de
; correction d'erreurs (PCE) : blocs de 15 octets + CRC + NUL.
; ===================================================================
; Term_Octet : A = octet reçu de la ligne (8 bits). Détruit tout.
; START PROCEDURE (1B 3A 69 44) est guetté ici, sur les octets reçus :
; MiniPavi le répète tant qu'il n'a pas pris la réponse, même quand la
; PCE tourne déjà chez nous. Réponse à chacun, la PCE repart au bloc 0.
Term_Octet:
    STA     Ligne8
    ANDA    #$7F
    LDB     BrutH+2             ; BrutH : les trois octets reçus d'avant
    CMPB    #$69
    BNE     To_Decale
    CMPA    #$44
    BNE     To_Decale
    LDD     BrutH
    CMPD    #$1B3A
    BEQ     To_Start
    LDA     Ligne8
    ANDA    #$7F
To_Decale:
    LDB     BrutH+1
    STB     BrutH
    LDB     BrutH+2
    STB     BrutH+1
    STA     BrutH+2
    LDA     Ligne8
    TST     PceOn
    BNE     To_Pce
    ANDA    #$7F
    LBRA    Livre
To_Start:
    LDD     BrutH+1             ; l'historique avance aussi
    STD     BrutH
    LDA     #$44
    STA     BrutH+2
    LDX     #Rep_Start
    JSR     Envoie_ChaineP
    LDA     PceOn
    STA     PceAvant
    LDA     #1
    STA     PceOn
    CLR     PceEtat             ; bloc entamé jeté
    CLR     PceNum
    CLR     PceDle
    TST     PceAvant
    BNE     To_Rien
    LDA     #$44                ; sans PCE avant : la séquence PRO2 finit à l'écran
    LBRA    Livre
To_Pce:
    LDB     PceEtat
    CMPB    #2
    BEQ     To_Resync
    CMPB    #1
    BEQ     To_Bloc
    TFR     A,B                 ; entre deux blocs : NUL sautés
    ANDB    #$7F
    BEQ     To_Rien
    CLR     PceN
    LDB     #1
    STB     PceEtat
To_Bloc:
    LDB     PceN
    LDX     #PceBuf
    STA     B,X
    INCB
    STB     PceN
    CMPB    #17
    BNE     To_Rien
    CLR     PceEtat
    TST     PceBuf+16           ; 17e octet : NUL
    BNE     To_Faux
    JSR     Pce_Crc
    LDB     PceBuf+15
    ANDB    #$7F
    PSHS    B
    CMPA    ,S+
    BNE     To_Faux
    INC     PceNum
    CLR     PceI
To_Livre:
    LDB     PceI
    CMPB    #15
    BHS     To_Rien
    INC     PceI
    LDX     #PceBuf
    LDA     B,X
    ANDA    #$7F
    TST     PceDle
    BEQ     To_PasDle
    CLR     PceDle
    BRA     To_Passe            ; DLE x : x tel quel
To_PasDle:
    CMPA    #$10
    BNE     To_Nul
    STA     PceDle
    BRA     To_Livre
To_Nul:
    TSTA
    BEQ     To_Livre            ; NUL de remplissage
To_Passe:
    JSR     Livre
    BRA     To_Livre
To_Faux:
    JSR     Pce_Nack
To_Rien:
    RTS
To_Resync:                      ; après NACK : SYN SYN 40+numéro
    ANDA    #$7F
    CMPA    #$16
    BNE     To_X
    INC     PceSyn
    RTS
To_X:
    LDB     PceSyn
    CMPB    #2
    BLO     To_Syn0
    LDB     PceNum
    ANDB    #$0F
    ORB     #$40
    PSHS    B
    CMPA    ,S+
    BNE     To_Syn0
    CLR     PceEtat             ; le serveur repart du bloc demandé
To_Syn0:
    CLR     PceSyn
    RTS

; Pce_Nack : NACK, 40 + numéro du bloc attendu ; on attend SYN SYN.
Pce_Nack:
    LDA     #$15
    JSR     Envoie_P
    LDA     PceNum
    ANDA    #$0F
    ORA     #$40
    JSR     Envoie_P
    LDA     #2
    STA     PceEtat
    CLR     PceSyn
    CLR     PceAtt
    RTS

; Pce_Garde : une fois par trame. 68 trames (1,12 s) sans SYN SYN après
; un NACK : on le renvoie (il a pu se perdre sur la ligne).
Pce_Garde:
    LDA     PceEtat
    CMPA    #2
    BNE     Pg_Fin
    INC     PceAtt
    LDA     PceAtt
    CMPA    #68
    BLO     Pg_Fin
    TST     PceOn
    BNE     Pce_Nack
Pg_Fin:
    RTS

; Pce_Crc : A = reste de PceBuf[0..14] par x^7 + x^3 + 1 (8 bits par
; octet, poids fort d'abord). Le reste est tenu décalé d'un bit à gauche.
Pce_Crc:
    CLRA
    LDX     #PceBuf
Pc_Octet:
    LDB     ,X+
    LDE     #8
Pc_Bit:
    STA     CrcTmp
    PSHS    B
    EORB    CrcTmp              ; bit 7 : bit du reste ^ bit de donnée
    PULS    B                   ; (PULS ne touche pas aux drapeaux)
    BPL     Pc_Zero
    LSLA
    EORA    #$12                ; (x^3 + 1) << 1
    BRA     Pc_Suiv
Pc_Zero:
    LSLA
Pc_Suiv:
    LSLB
    DECE
    BNE     Pc_Bit
    CMPX    #PceBuf+15
    BNE     Pc_Octet
    LSRA
    RTS

; Livre : A = octet (7 bits) pour l'écran ; d'abord les demandes du
; serveur (sur les trois octets précédents, Hist) : STOP, ENQROM, STATUS.
Livre:
    STA     Brut
    LDD     Hist
    CMPD    #$1B3A
    BNE     Lv_Pro1
    LDB     Hist+2
    LDA     Brut
    CMPA    #$44
    BNE     Lv_Pro1
    CMPB    #$6A                ; STOP PROCEDURE (START : Term_Octet)
    BNE     Lv_Pro1
    LDX     #Rep_Stop
    JSR     Envoie_ChaineP
    CLR     PceOn
    BRA     Lv_Hist
Lv_Pro1:
    LDD     Hist+1
    CMPD    #$1B39
    BNE     Lv_Hist
    LDA     Brut
    CMPA    #$7B                ; ENQROM
    BNE     Lv_Status
    LDX     #Rep_Rom
    JSR     Envoie_ChaineP
    BRA     Lv_Hist
Lv_Status:
    CMPA    #$72                ; STATUS FONCTIONNEMENT
    BNE     Lv_Hist
    LDX     #Rep_Stop           ; 1B 3A 73, puis l'octet de status
    LDA     ,X+
    JSR     Envoie_P
    LDA     ,X+
    JSR     Envoie_P
    LDA     ,X+
    JSR     Envoie_P
    LDA     #$40
    TST     PceOn
    BEQ     Lv_St
    LDA     #$44
Lv_St:
    JSR     Envoie_P
Lv_Hist:
    LDD     Hist+1
    STD     Hist
    LDA     Brut
    STA     Hist+2
    BRA     Vt_Octet

; Envoie_ChaineP : X = octets (0 final), en 7 bits + parité paire.
Envoie_ChaineP:
    LDA     ,X+
    BEQ     Ecp_Fin
    JSR     Envoie_P
    BRA     Envoie_ChaineP
Ecp_Fin:
    RTS

; Vt_Octet : A = octet reçu. Détruit tout.
Vt_Octet:
    ANDA    #$7F
    LDB     Etat
    LBNE    Sequence
    CMPA    #$20
    LBLO    Controle
    TST     G1
    BNE     Mosaique
    CMPA    #$7F
    BEQ     Vo_Rien
    STA     Brut                ; texte : la lettre reçue
    LDX     #Tab_G0
Vo_G0:
    LDB     ,X++
    BEQ     Vo_Diac
    CMPB    Brut
    BNE     Vo_G0
    LDA     -1,X                ; barre horizontale du Minitel
Vo_Diac:
    LDB     Diac
    BEQ     Vo_Pose
    LDX     #Tab_Combi
Vo_Cb:
    LDB     ,X
    BEQ     Vo_CbFin
    CMPB    Diac
    BNE     Vo_CbSuiv
    LDB     1,X
    CMPB    Brut
    BNE     Vo_CbSuiv
    LDA     2,X                 ; lettre accentuée (CP437)
    BRA     Vo_CbFin
Vo_CbSuiv:
    LEAX    3,X
    BRA     Vo_Cb
Vo_CbFin:
    CLR     Diac
Vo_Pose:
    BRA     Pose_Texte
Vo_Rien:
    RTS

; A = code CP437 : texte, largeur courante.
Pose_Texte:
    STA     PoseG
    CLR     PoseT
    LDA     Larg
    STA     PoseL
    BRA     Pose

; Mosaïque : valeur = b0-b4 du code, et son bit 6 en bit 5 ;
; genre 1 (contiguë) ou 2 (disjointe).
Mosaique:
    TFR     A,B
    ANDA    #$1F
    ANDB    #$40
    LSRB
    PSHS    B
    ORA     ,S+
    STA     PoseG
    LDA     #1
    TST     Disj
    BEQ     Mo_Genre
    INCA
Mo_Genre:
    STA     PoseT
    LDA     #1
    STA     PoseL
    BRA     Pose

; Pose : la case (Lig, Col) reçoit PoseG/PoseT et l'attribut courant
; (bit 7 si mosaïque), puis avance de PoseL ; retenu pour REP. Double
; largeur : la case suivante devient une espace de même attribut.
Pose:
    LDD     PoseG               ; PoseG, PoseT
    STD     DerG
    LDA     PoseL
    STA     DerL
    LDA     #1
    STA     DerOk
    CLR     PoseP
    TST     PoseT
    BEQ     Po_Attr
    LDA     #$80
    STA     PoseP
Po_Attr:
    JSR     Attribut            ; B = attribut
    STB     AttrTmp
    JSR     Cellule             ; U = LG + Lig*40 + Col
    LDD     PoseG
    STA     ,U
    STB     LT-LG,U
    LDA     AttrTmp
    STA     LA-LG,U
    LDA     PoseL
    CMPA    #2
    BNE     Po_Marque
    LDA     Col
    CMPA    #NCOL-1
    BHS     Po_Marque
    LDA     #$20
    STA     1,U
    CLR     LT-LG+1,U
    LDA     AttrTmp
    STA     LA-LG+1,U
Po_Marque:
    JSR     Marque
    LDB     PoseL
    ; continue dans Avance

; Avance : B colonnes ; au bout de la rangée, rangée suivante (24 -> 1) ;
; la ligne de service (rangée 0) reste bloquée en colonne 39.
Avance:
    ADDB    Col
    CMPB    #NCOL
    BLO     Av_Pose
    TST     Lig
    BNE     Av_Rangee
    LDB     #NCOL-1
    BRA     Av_Pose
Av_Rangee:
    CLRB
    LDA     Lig
    CMPA    #LIGNES-1
    BHS     Av_Un
    INCA
    BRA     Av_Lig
Av_Un:
    LDA     #1
Av_Lig:
    STA     Lig
Av_Pose:
    STB     Col
    RTS

; Attribut : B = fond << 4 | premier plan | 8 | PoseP (inversion : échange).
Attribut:
    LDX     #Tab_Coul
    LDA     Fg
    LDA     A,X
    LDB     Bg
    LDB     B,X
    TST     Inv
    BEQ     At_Pose
    EXG     A,B
At_Pose:
    STA     AttrFg
    ASLB
    ASLB
    ASLB
    ASLB
    ORB     AttrFg
    ORB     #8
    ORB     PoseP
    RTS

Cellule:                        ; U = LG + Lig*40 + Col ; détruit D
    LDA     #NCOL
    LDB     Lig
    MUL
    ADDB    Col
    ADCA    #0
    ADDD    #LG
    TFR     D,U
    RTS

Marque:                         ; la rangée Lig est à recopier
    LDX     #Sale
    LDB     Lig
    LDA     #1
    STA     B,X
    RTS

; --- Codes de contrôle ($00-$1F) ---
Controle:
    CMPA    #$08
    LBEQ    Ct_BS
    CMPA    #$09
    LBEQ    Ct_HT
    CMPA    #$0A
    LBEQ    Ct_LF
    CMPA    #$0B
    LBEQ    Ct_VT
    CMPA    #$0C
    LBEQ    Ct_FF
    CMPA    #$0D
    LBEQ    Ct_CR
    CMPA    #$0E
    LBEQ    Ct_SO
    CMPA    #$0F
    LBEQ    Ct_SI
    CMPA    #$11
    LBEQ    Ct_CON
    CMPA    #$14
    LBEQ    Ct_COFF
    CMPA    #$12
    LBEQ    Ct_REP
    CMPA    #$13
    LBEQ    Ct_SEP
    CMPA    #$18
    LBEQ    Ct_CAN
    CMPA    #$19
    LBEQ    Ct_SS2
    CMPA    #$1B
    LBEQ    Ct_ESC
    CMPA    #$1E
    LBEQ    Ct_RS
    CMPA    #$1F
    LBEQ    Ct_US
    RTS
Ct_BS:
    LDB     Col
    BEQ     Ct_BS0
    DEC     Col
    RTS
Ct_BS0:
    LDA     Lig
    BEQ     Ct_Fin
    LDB     #NCOL-1
    STB     Col
    CMPA    #1
    BHI     Ct_Monte
    LDA     #LIGNES
Ct_Monte:
    DECA
    STA     Lig
Ct_Fin:
    RTS
Ct_HT:
    LDB     #1
    LBRA    Avance
Ct_LF:
    LDA     Lig
    BEQ     Ct_LF1
    CMPA    #LIGNES-1
    BHS     Ct_LF1
    INCA
    STA     Lig
    RTS
Ct_LF1:
    LDA     #1
    STA     Lig
    RTS
Ct_VT:
    LDA     Lig
    CMPA    #1
    BHI     Ct_Monte
    LDA     #LIGNES-1
    STA     Lig
    RTS
Ct_CR:
    CLR     Col
    RTS
Ct_SO:
    LDA     #1
    STA     G1
    RTS
Ct_SI:
    CLR     G1
    RTS
Ct_CON:                         ; curseur visible
    LDA     #1
    STA     Curseur
    RTS
Ct_COFF:
    CLR     Curseur
    RTS
Ct_REP:
    LDA     #6
    STA     Etat
    RTS
Ct_SEP:
    LDA     #1
    STA     Reste
    STA     Etat                ; 1 : sauter Reste octets
    RTS
Ct_SS2:
    LDA     #7
    STA     Etat
    RTS
Ct_ESC:
    LDA     #3
    STA     Etat
    RTS
Ct_RS:
    LDA     #1
    STA     Lig
    CLR     Col
    LBRA    Raz_Attributs
Ct_US:
    LDA     #4
    STA     Etat
    RTS
Ct_FF:                          ; rangées 1-24 en blanc, la 0 reste
    LDX     #CstBlanc
    LDY     #LG+NCOL
    LDW     #(LIGNES-1)*NCOL
    TFM     X,Y+
    LDX     #CstZero
    LDY     #LT+NCOL
    LDW     #(LIGNES-1)*NCOL
    TFM     X,Y+
    LDX     #CstAttr
    LDY     #LA+NCOL
    LDW     #(LIGNES-1)*NCOL
    TFM     X,Y+
    JSR     Tout_Sale
    LDA     #1
    STA     Lig
    CLR     Col
    LBRA    Raz_Attributs
Ct_CAN:                         ; espaces jusqu'au bout de la rangée
    CLR     PoseP
    JSR     Attribut
    STB     AttrTmp
    JSR     Cellule
    LDA     #NCOL
    SUBA    Col                 ; cases restantes
Cn_Boucle:
    LDB     #$20
    STB     ,U
    CLR     LT-LG,U
    LDB     AttrTmp
    STB     LA-LG,U
    LEAU    1,U
    DECA
    BNE     Cn_Boucle
    LBRA    Marque

; --- Suite d'une séquence : B = Etat, A = octet ---
Sequence:
    CLR     Etat
    CMPB    #1
    BEQ     Sq_Saute
    CMPB    #2
    BEQ     Sq_CSI
    CMPB    #3
    LBEQ    Echap
    CMPB    #4
    BEQ     Sq_US
    CMPB    #5
    BEQ     Sq_US2
    CMPB    #6
    BEQ     Sq_REP
    BRA     Sq_SS2              ; 7
Sq_Saute:
    DEC     Reste
    BEQ     Sq_Fin
    STB     Etat                ; encore : B = 1
Sq_Fin:
    RTS
Sq_CSI:                         ; jusqu'à un final $40-$7E
    CMPA    #$40
    BLO     Sq_CSIenc
    CMPA    #$7E
    BLS     Sq_Fin
Sq_CSIenc:
    STB     Etat
    RTS
Sq_US:
    STA     UsLig
    LDA     #5
    STA     Etat
    RTS
Sq_US2:                         ; rang $40-$58, colonne $41-$68
    LDB     UsLig
    CMPB    #$40
    BLO     Sq_Fin
    CMPB    #$40+LIGNES-1
    BHI     Sq_Fin
    CMPA    #$41
    BLO     Sq_Fin
    CMPA    #$40+NCOL
    BHI     Sq_Fin
    SUBB    #$40
    STB     Lig
    SUBA    #$41
    STA     Col
    LBRA    Raz_Attributs
Sq_REP:
    TST     DerOk
    BEQ     Sq_Fin
    ANDA    #$3F
    BEQ     Sq_Fin
    STA     RepN
Sq_RepBoucle:
    LDD     DerG
    STD     PoseG
    LDA     DerL
    STA     PoseL
    JSR     Pose
    DEC     RepN
    BNE     Sq_RepBoucle
    RTS
Sq_SS2:
    CMPA    #$41
    BLO     Sq_Spec
    CMPA    #$4F
    BHI     Sq_Spec
    STA     Diac                ; diacritique : pour la lettre suivante
    RTS
Sq_Spec:
    LDX     #Tab_Speciaux
Sq_SpBoucle:
    LDB     ,X++
    BEQ     Sq_Fin
    STA     Brut
    CMPB    Brut
    BNE     Sq_SpBoucle
    LDA     -1,X
    LBRA    Pose_Texte

; --- ESC + A ---
Echap:
    CMPA    #$40
    BLO     Ec_Bas
    CMPA    #$47
    BHI     Ec_Taille
    SUBA    #$40
    STA     Fg
    RTS
Ec_Taille:
    CMPA    #$4C
    BLO     Ec_Ret
    CMPA    #$4F
    BHI     Ec_Fond
    LDB     #1
    CMPA    #$4E
    BLO     Ec_Larg
    INCB
Ec_Larg:
    STB     Larg
    RTS
Ec_Fond:
    CMPA    #$50
    BLO     Ec_Ret
    CMPA    #$57
    BHI     Ec_Divers
    SUBA    #$50
    STA     Bg
    RTS
Ec_Divers:
    CMPA    #$59
    BNE     Ec_5A
    CLR     Disj
    RTS
Ec_5A:
    CMPA    #$5A
    BNE     Ec_5B
    LDA     #1
    STA     Disj
    RTS
Ec_5B:
    CMPA    #$5B
    BNE     Ec_5C
    LDA     #2                  ; CSI
    STA     Etat
    RTS
Ec_5C:
    CMPA    #$5C
    BNE     Ec_5D
    CLR     Inv
    RTS
Ec_5D:
    CMPA    #$5D
    BNE     Ec_Ret
    LDA     #1
    STA     Inv
Ec_Ret:
    RTS
Ec_Bas:                         ; $20-$3F
    CMPA    #$39
    BLO     Ec_Desig
    CMPA    #$3B
    BHI     Ec_Ret
    SUBA    #$38                ; PRO1/2/3 : 1, 2 ou 3 octets
    BRA     Ec_Saute
Ec_Desig:
    CMPA    #$20
    BLO     Ec_Ret
    CMPA    #$2F
    BHI     Ec_Ret
    LDB     #1
    CMPA    #$23
    BNE     Ec_Saute1
    INCB
Ec_Saute1:
    TFR     B,A
Ec_Saute:
    STA     Reste
    LDA     #1
    STA     Etat
    RTS

; ===================================================================
; DONNÉES
; ===================================================================
    include "minitel_data.inc"

CstBlanc        fcb $20
CstAttr         fcb ATT_DEFAUT
CstZero         fcb 0

; Touches de fonction du Minitel : code de scan_keyboard, lettre après SEP
Tab_Fonctions
    fcb $0D,'A'                 ; Entrée      ENVOI
    fcb KEY_PGUP,'B'            ; Pg.préc     RETOUR
    fcb KEY_INS,'C'             ; Inser       RÉPÉTITION
    fcb KEY_END,'D'             ; Fin         GUIDE
    fcb KEY_DEL,'E'             ; Suppr       ANNULATION
    fcb KEY_HOME,'F'            ; Début       SOMMAIRE
    fcb $08,'G'                 ; Ret.arr.    CORRECTION
    fcb KEY_PGDN,'H'            ; Pg.suiv     SUITE
    fcb 0
Tab_Fleches     fcc "ABDC"      ; haut, bas, gauche, droite (ESC [ x)
; Clavier AZERTY (Latin-1) -> SS2 + code G2 (+ lettre, ou 0)
Tab_Clavier
    fcb $E9,$42,'e'             ; é
    fcb $E8,$41,'e'             ; è
    fcb $E0,$41,'a'             ; à
    fcb $F9,$41,'u'             ; ù
    fcb $E7,$4B,'c'             ; ç
    fcb $A3,$23,0               ; £
    fcb $B0,$30,0               ; °
    fcb $A7,$27,0               ; §
    fcb 0

Cmd_Appel       fcb $0D
                fcn "ATE0&D0B2M1S91=6DT"   ; S91=6 : émission à -6 dBm (ligne de box)
Num_MiniPavi    fcn "0972101721,,,,,"   ; 3615... : MiniPavi par le téléphone ; 5 x 2 s :
                                    ; le message vocal fini avant l'écoute
Cmd_ATH         fcc "ATH"           ; FCC : FCN mettrait son 0 AVANT le CR
                fcb $0D,0
Cmd_Plus        fcn "+++"
Rep_Connect     fcn "CONNECT"
Mots_Echec      fcn "NO CARRIER"
                fcn "BUSY"
                fcn "ERROR"
                fcn "NO DIAL"
                fcn "NO ANSWER"
                fcb 0
Rep_NoCarrier   fcn "NO CARRIER"
Rep_Start       fcb $1B,$3A,$73,$44,0   ; REP STATUS FONCTIONNEMENT, PCE en marche
Rep_Stop        fcb $1B,$3A,$73,$40,0   ; ... PCE arrêtée
Rep_Rom         fcb $01,'C','u','4',$04,0   ; ENQROM : un Minitel 1B

Txt_Titre       fcn " MINITEL "
Txt_TitreAppel  fcn " Appel "
Textes_Dialogue
    fcb DLG_X+2,DLG_Y+2
    fdb Txt_Numero
    fcb DLG_X+2,DLG_Y+4
    fdb Txt_Aide1
    fcb DLG_X+2,DLG_Y+5
    fdb Txt_Aide2
    fcb DLG_X+2,DLG_Y+6
    fdb Txt_Aide3
    fcb 0
Txt_Numero      fcn "Numero :"
Txt_Aide1       fcn "3615, 3611... : MiniPavi (0972101721)"
Txt_Aide2       fcn "0 : page d'essai de modem.py (sur le PC)"
Txt_Aide3       fcn "Entree : appeler     Echap : quitter"
Txt_Touches1    fcn " Entree ENVOI   Ret.arr CORRECTION   Suppr ANNULATION   Pg.prec RETOUR"
Txt_Touches2    fcn " Pg.suiv SUITE   Debut SOMMAIRE   Fin GUIDE   Inser REPETITION   Echap FIN"
Txt_Pret        fcn "MINITEL - modem V.23 ou tools/minitel/modem.py, 115200 bauds"
Txt_Appel       fcn "Appel en cours...   (Echap : abandon)"
Txt_EnLigne     fcn "En ligne     Echap : raccrocher     Ctrl+F : fenetre / plein ecran"
Txt_Raccrochage fcn "Raccrochage..."
Txt_Fin         fcn "Communication terminee"
Txt_Muet        fcn "Le modem ne repond pas (allume ?)"
Txt_Raccroche   fcn "Le serveur a raccroche."

; ===================================================================
; VARIABLES
; ===================================================================
NumBuf          fcc "3615"
                rmb NUM_MAX+1-4
Compte          rmb 2
LigBuf          rmb 24
LigLen          rmb 1
NcIdx           rmb 1
Recu            rmb 1
; couche terminal (Terminal) : PCE
PceOn           rmb 1           ; <> 0 : la PCE est en marche
PceEtat         rmb 1           ; 0 entre deux blocs, 1 dans un bloc, 2 attend SYN SYN
PceN            rmb 1           ; octets du bloc reçus
PceNum          rmb 1           ; numéro du bloc attendu (modulo 16 : bits 0-3)
PceSyn          rmb 1
PceDle          rmb 1
PceI            rmb 1
PceAtt          rmb 1           ; trames depuis le NACK
CrcTmp          rmb 1
PceBuf          rmb 17
Hist            rmb 3           ; les trois derniers octets passés à l'écran
BrutH           rmb 3           ; les trois derniers octets reçus (7 bits)
Ligne8          rmb 1           ; l'octet reçu, 8 bits
PceAvant        rmb 1
RenduN          rmb 1
RenduTours      rmb 1
RenduLig        rmb 1
; état du décodeur (Ecran)
Lig             rmb 1
Col             rmb 1
Fg              rmb 1
Bg              rmb 1
Inv             rmb 1
Disj            rmb 1
Larg            rmb 1
G1              rmb 1
Etat            rmb 1           ; 0, 1 saute, 2 CSI, 3 ESC, 4-5 US, 6 REP, 7 SS2
Reste           rmb 1
Diac            rmb 1
UsLig           rmb 1
Brut            rmb 1
RepN            rmb 1
AttrTmp         rmb 1
AttrFg          rmb 1
PoseG           rmb 1           ; PoseG, PoseT : lus ensemble (LDD)
PoseT           rmb 1
PoseL           rmb 1
PoseP           rmb 1           ; $80 : mosaïque (page 1)
DerG            rmb 1           ; dernier caractère posé (REP) : DerG, DerT
DerT            rmb 1
DerL            rmb 1
DerOk           rmb 1
Mode            rmb 1           ; 0 fenêtre 40 x 25, 1 plein écran 80 x 25
Curseur         rmb 1           ; curseur du Minitel : 1 après CON, 0 après COFF
AffCurseur      rmb 1           ; 1 : en ligne, le curseur est montré
StatutCourant   rmb 2           ; message de la rangée de statut, ou 0
RbN             rmb 1           ; Rendu : rangées converties
RbK             rmb 1
RbLig           rmb RENDU_40
RbDest          rmb 2
RbLarg          rmb 2
BaseTmp         rmb 1
BrutTmp         rmb 1
Sale            rmb LIGNES      ; rangées à redessiner
LG              rmb LIGNES*NCOL ; écran logique : code (CP437 ou mosaïque 0-63)
LT              rmb LIGNES*NCOL ;                 genre (0 texte, 1, 2 mosaïque)
LA              rmb LIGNES*NCOL ;                 attribut
RbChr           rmb RB_ATT*2    ; tampon de rendu : caractères puis attributs
BarreSauve      rmb SAUVE_OCTETS*2
EcranOSM        rmb 80*LIGNES*2 ; l'écran d'OSM-VISION au départ (deux plans)
DlgSauve        rmb (DLG_W+1)*(DLG_H+1)*2

; Les services d'affichage (lib/vis.inc) : copie propre à l'application.
    include "../lib/vision.asm"
