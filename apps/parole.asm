; ===================================================================
; PAROLE.ASM - Synthèse de la parole en français pour OSM-VISION
; ===================================================================
; On tape une phrase, la machine la dit. Aucune puce vocale : l'AY-3-8910
; de la carte SD-KBD-SON sert de convertisseur (volumes des voies A et C,
; ton et bruit coupés), le timer 3 du 6840 d'horloge des échantillons, et
; tout le reste est du logiciel, à la manière de S.A.M. (1982).
;
; SOURCE UNIQUE : tools/parole/parole.py. Il contient les règles de
; prononciation, la table des phonèmes, la prosodie et un MODÈLE EXACT de
; ce programme ; il génère apps/parole_data.inc (ne pas l'éditer) et
; des .wav pour écouter sur le PC ce que la carte dira.
;
; CHAÎNE DE TRAITEMENT (comme dans parole.py, fonction par fonction) :
;   1. Normalise : minuscules, sigles épelés (OSM -> « o èss èm »),
;      nombres en lettres (0 à 9999), ponctuation ramenée à , . ?
;   2. Word_Ph : règles « gauche [lettres] droite = phonèmes », la
;      première qui convient pour la lettre courante gagne ;
;   3. groupes : un par virgule, point, point d'interrogation (au plus
;      MAX_PH phonèmes, coupé entre deux mots) ;
;   4. Build_Frames : une trame de paramètres toutes les 10 ms (formants,
;      amplitudes, souffle, période de la voix), transitions de 30 ms,
;      mélodie (déclinaison, fin montante ou descendante) ;
;   5. Play : 7 200 échantillons/s, chacun en deux tranches de 128 cycles
;      (timer 3 à 14,4 kHz). Tranche A : l'échantillon précédent devient
;      un couple de volumes (TabA, TabC : la somme des niveaux de l'AY la
;      plus proche) ; tranche B : les deux volumes écrits coup sur coup
;      (STD : registre puis valeur), puis l'échantillon suivant calculé.
;      Trois sinus (formants) lus dans une table sinus x amplitude, remis
;      en phase à chaque période de la voix ; souffle = hasard ajouté aux
;      phases. CODE AUTOMODIFIANT : chaque trame réécrit les opérandes de
;      la boucle (incréments, pages de la table, masque du souffle).
;
; MÉMOIRE : programme et tampon de trames en $4000-$6FFF ; table sinus x
; amplitude construite au démarrage en $7000-$7FFF (16 pages de 256).
;
; Touches : texte (accents é è à ç ù compris), Retour arrière, Entrée
; pour parler, Tab pour changer de voix, Echap pour revenir.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"
    include "../lib/ui.inc"
    include "../lib/vis.inc"

    export App_Start

; Services d'OSM-VISION utilisés : jusqu'à vis_Sound_Stop
VIS_REQUIS      equ (vis_Sound_Stop/2)+1

WIN_X           equ 5
WIN_Y           equ 4
WIN_W           equ 70
WIN_H           equ 16
TXT_X           equ WIN_X+3
IN_X            equ WIN_X+3
IN_Y            equ WIN_Y+4
IN_MAX          equ 62          ; caractères tapés au plus
PH_Y            equ WIN_Y+7     ; phonèmes du groupe en cours
ETAT_Y          equ WIN_Y+9
VOIX_Y          equ WIN_Y+11

SINAMP          equ $7000       ; table sinus x amplitude (16 x 256)
FR_TAILLE       equ 12          ; octets par trame
FR_LIMITE       equ SINAMP-FR_TAILLE
NORM_MAX        equ 900         ; texte normalisé (les nombres s'allongent)
MILIEU          equ 60          ; échantillon du silence (0..120)
TICK            equ 127         ; timer 3 : 128 périodes E par impulsion

; Trame (FR_TAILLE octets) : incréments F1 F2 F3 (déjà diminués de la
; moitié du masque), masque du souffle, pages de la table pour A1 A2 A3,
; période de la voix (0 : pas de voix)
FR_I1           equ 0
FR_I2           equ 2
FR_I3           equ 4
FR_MASQUE       equ 6
FR_P1           equ 8
FR_P2           equ 9
FR_P3           equ 10
FR_PER          equ 11
; Phonème (PhonTbl, 16 octets)
PH_I1           equ 0
PH_A1           equ 6
PH_DUR          equ 9
PH_MASQUE       equ 10
PH_VOISE        equ 12
PH_SORTE        equ 13
PH_SYMB         equ 14

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
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #WIN_X
    LDB     #WIN_Y
    LDW     #(WIN_W*256)+WIN_H
    LDY     #TxtTitre
    JSR     [VIS_TABLE+vis_Window]
    JSR     [VIS_TABLE+vis_Sync_End]
    LDX     #TxtAide1
    LDB     #WIN_Y+2
    JSR     Text_Line
    LDX     #TxtAide2
    LDB     #WIN_Y+13
    JSR     Text_Line
    LDX     #TxtPrepare
    JSR     Etat
    JSR     Build_SinAmp
    CLR     InLen
    CLR     Voix
    JSR     Show_Voix
    LDX     #TxtPret
    JSR     Etat

; -------------------------------------------------------------------
; Boucle : une phrase, puis on la dit
; -------------------------------------------------------------------
Main_Loop:
    JSR     Edit_Line
    BCS     Quit
    LDX     #TxtParle
    JSR     Etat
    JSR     Normalise
    JSR     Parse_Speak
    LDX     #TxtPret
    JSR     Etat
    BRA     Main_Loop

Quit:
    RTS                         ; OSM-VISION restaure l'écran

; -------------------------------------------------------------------
; Ecran
; -------------------------------------------------------------------
; X = texte (CP437, 0 final), B = ligne : à TXT_X, attribut COLOR_TEXT.
Text_Line:
    PSHS    B,X
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDX     1,S
    LDB     ,S
    LDA     #TXT_X
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
    PULS    B,X,PC

; X = texte de la ligne d'état.
Etat:
    LDB     #ETAT_Y
    BRA     Text_Line

Show_Voix:
    LDB     Voix
    ASLB
    LDX     #VoixNoms
    LDX     B,X
    LDB     #VOIX_Y
    BRA     Text_Line

; Ligne de saisie : InBuf (Latin-1) affiché en CP437, curseur, espaces.
Draw_Input:
    LDX     #InBuf
    LDU     #Disp
    LDB     InLen
DI_Loop:
    BEQ     DI_Cur
    LDA     ,X+
    JSR     To437
    STA     ,U+
    DECB
    BRA     DI_Loop
DI_Cur:
    LDA     #'_'
    STA     ,U+
DI_Pad:
    CMPU    #Disp+IN_MAX+1
    BHS     DI_End
    LDA     #$20
    STA     ,U+
    BRA     DI_Pad
DI_End:
    CLR     ,U
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDX     #Disp
    LDA     #IN_X
    LDB     #IN_Y
    LDE     #COLOR_SEL
    JSR     [VIS_TABLE+vis_Text]
    JMP     [VIS_TABLE+vis_Sync_End]

; A = caractère Latin-1 -> A = caractère CP437 (accents de la police).
To437:
    CMPA    #$80
    BLO     T4_End
    PSHS    X
    LDX     #Cp437Tbl
T4_Find:
    TST     ,X
    BEQ     T4_Inconnu
    CMPA    ,X++
    BNE     T4_Find
    LDA     -1,X
    PULS    X,PC
T4_Inconnu:
    LDA     #'?'
    PULS    X
T4_End:
    RTS

; Saisie. Sortie : C = 0 Entrée (texte non vide), C = 1 Echap.
Edit_Line:
    JSR     Draw_Input
EL_Key:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #$1B
    BEQ     EL_Esc
    CMPA    #$0D
    BEQ     EL_Enter
    CMPA    #$08
    BEQ     EL_Back
    CMPA    #$09
    BEQ     EL_Tab
    CMPA    #$20
    BLO     EL_Key
    CMPA    #$7F
    BLO     EL_Put
    CMPA    #$C0                ; lettres accentuées Latin-1
    BLO     EL_Key
EL_Put:
    LDB     InLen
    CMPB    #IN_MAX
    BHS     EL_Key
    LDX     #InBuf
    ABX
    STA     ,X
    INC     InLen
    BRA     Edit_Line
EL_Back:
    TST     InLen
    BEQ     EL_Key
    DEC     InLen
    BRA     Edit_Line
EL_Tab:
    LDA     Voix
    INCA
    CMPA    #3
    BLO     EL_TSet
    CLRA
EL_TSet:
    STA     Voix
    JSR     Show_Voix
    BRA     EL_Key
EL_Enter:
    TST     InLen
    BEQ     EL_Key
    ANDCC   #$FE
    RTS
EL_Esc:
    ORCC    #1
    RTS

; -------------------------------------------------------------------
; 1. Normalisation : InBuf -> NormBuf (texte des règles, 0 final)
; -------------------------------------------------------------------
; B = caractère -> A = sa classe (ClassTbl). Préserve B, X, Y, U.
Class_Of:
    PSHS    X
    LDX     #ClassTbl
    ABX
    LDA     ,X
    PULS    X,PC

; A -> NormBuf (sauf s'il est plein). Préserve tout sauf CC.
Put_N:
    CMPU    #NormBuf+NORM_MAX-1
    BHS     PN_End
    STA     ,U+
PN_End:
    RTS

; Y = chaîne (0 final) -> NormBuf. Détruit A, Y.
Put_Str:
    LDA     ,Y+
    BEQ     PSt_End
    BSR     Put_N
    BRA     Put_Str
PSt_End:
    RTS

Put_Space:
    LDA     #$20
    BRA     Put_N

; B = indice -> Y = MotUnite[B] écrit dans NormBuf.
Put_Unite:
    LDY     #MotUnite
Put_Mot:                        ; Y = table de pointeurs, B = indice
    ASLB
    LDY     B,Y
    BRA     Put_Str

Normalise:
    LDU     #NormBuf
    LDA     #$20                ; deux espaces : les contextes de gauche
    STA     ,U+                 ; ne sortent jamais du tampon
    STA     ,U+
    LDX     #InBuf
    LDB     InLen
    ABX
    STX     InEnd
    LDX     #InBuf
N_Loop:
    CMPX    InEnd
    LBHS    N_End
    LDB     ,X
    BSR     Class_Of
    BITA    #C_CHIF
    LBNE    N_Num
    BITA    #C_LETTRE+C_MAJ
    BNE     N_Word
    LDA     #','
    CMPB    #','
    BEQ     N_Punct
    CMPB    #';'
    BEQ     N_Punct
    CMPB    #':'
    BEQ     N_Punct
    LDA     #'.'
    CMPB    #'.'
    BEQ     N_Punct
    CMPB    #'!'
    BEQ     N_Punct
    LDA     #'?'
    CMPB    #'?'
    BEQ     N_Punct
    LDA     #$20
N_Punct:
    BSR     Put_N
    LEAX    1,X
    BRA     N_Loop

; Mot : sigle épelé, ou recopié en minuscules.
N_Word:
    STX     WStart
    CLR     WMaj                ; toutes majuscules ?
    CLR     WMajVoy             ; une voyelle majuscule ?
    CLR     WLen
NW_Scan:
    CMPX    InEnd
    BHS     NW_Fin
    LDB     ,X
    LBSR    Class_Of
    BITA    #C_LETTRE+C_MAJ
    BEQ     NW_Fin
    BITA    #C_MAJ
    BNE     NW_Maj
    INC     WMaj                ; une minuscule : pas un sigle
NW_Maj:
    BITA    #C_MAJVOY
    BEQ     NW_Next
    INC     WMajVoy
NW_Next:
    INC     WLen
    LEAX    1,X
    BRA     NW_Scan
NW_Fin:
    STX     WEnd
    LDX     WStart
    TST     WMaj
    BNE     NW_Copy
    LDA     WLen
    CMPA    #2
    BLO     NW_Copy
    CMPA    #3
    BLS     NW_Sigle
    TST     WMajVoy
    BNE     NW_Copy
NW_Sigle:
    CMPX    WEnd
    BHS     NW_SFin
    LBSR    Put_Space
    LDB     ,X+
    SUBB    #'A'
    LDY     #MotLettre
    LBSR    Put_Mot
    BRA     NW_Sigle
NW_SFin:
    LBSR    Put_Space
    LBRA    N_Loop
NW_Copy:
    CMPX    WEnd
    LBHS    N_Loop
    LDB     ,X+
    LBSR    Class_Of
    BITA    #C_MAJ
    BEQ     NW_Low
    ADDB    #32
NW_Low:
    TFR     B,A
    LBSR    Put_N
    BRA     NW_Copy

; Nombre : 1 à 4 chiffres en lettres, au-delà chiffre par chiffre.
N_Num:
    STX     WStart
    CLR     WLen
NN_Scan:
    CMPX    InEnd
    BHS     NN_Fin
    LDB     ,X
    LBSR    Class_Of
    BITA    #C_CHIF
    BEQ     NN_Fin
    INC     WLen
    LEAX    1,X
    BRA     NN_Scan
NN_Fin:
    STX     WEnd
    LDX     WStart
    LBSR    Put_Space
    LDA     WLen
    CMPA    #4
    BHI     NN_Chiffres
    LDD     #0
NN_Val:
    CMPX    WEnd
    BHS     NN_Dire
    STD     NTmp                ; D = D x 10 + chiffre
    LSLD
    LSLD
    ADDD    NTmp
    LSLD
    STD     NTmp
    LDB     ,X+
    SUBB    #'0'
    CLRA
    ADDD    NTmp
    BRA     NN_Val
NN_Dire:
    PSHS    X
    JSR     Num_Words
    PULS    X
    LBSR    Put_Space
    LBRA    N_Loop
NN_Chiffres:
    CMPX    WEnd
    BHS     NN_CFin
    LDB     ,X+
    SUBB    #'0'
    LBSR    Put_Unite
    LBSR    Put_Space
    BRA     NN_Chiffres
NN_CFin:
    LBRA    N_Loop

N_End:
    LDA     #$20
    LBSR    Put_N
    CLR     ,U
    RTS

; D = 0..9999 -> mots dans NormBuf (nombre() de parole.py).
Num_Words:
    CMPD    #0
    BNE     NW1
    CLRB
    LBRA    Put_Unite
NW1:
    CLR     NMil
NW_Mil:
    CMPD    #1000
    BLO     NW_Cent
    SUBD    #1000
    INC     NMil
    BRA     NW_Mil
NW_Cent:
    STD     NTmp
    LDB     NMil
    BEQ     NW_C0
    CMPB    #1
    BEQ     NW_M1
    LBSR    Put_Unite
    LBSR    Put_Space
NW_M1:
    LDY     #MotMille
    LBSR    Put_Str
    LBSR    Put_Space
NW_C0:
    LDD     NTmp
    CLR     NMil                ; centaines
NW_C1:
    CMPD    #100
    BLO     NW_Reste
    SUBD    #100
    INC     NMil
    BRA     NW_C1
NW_Reste:
    STB     NRest
    LDB     NMil
    BEQ     NW_R0
    CMPB    #1
    BEQ     NW_C2
    LBSR    Put_Unite
    LBSR    Put_Space
NW_C2:
    LDY     #MotCent
    LBSR    Put_Str
    LBSR    Put_Space
NW_R0:
    LDB     NRest
    BEQ     NW_End
    BRA     Moins_100
NW_End:
    RTS

; B = 1..99 -> mots (moins_de_100() de parole.py).
Moins_100:
    CMPB    #17
    LBLO    Put_Unite
    CMPB    #20
    BHS     M1_Diz
    PSHS    B
    LDB     #10
    LBSR    Put_Unite
    LBSR    Put_Space
    PULS    B
    SUBB    #10
    LBRA    Put_Unite
M1_Diz:
    CMPB    #70
    BHS     M1_Soix
    CLR     NDiz
M1_D:
    CMPB    #10
    BLO     M1_DOk
    SUBB    #10
    INC     NDiz
    BRA     M1_D
M1_DOk:
    PSHS    B                   ; unités
    LDB     NDiz
    LDY     #MotDiz
    LBSR    Put_Mot
    PULS    B
    TSTB
    BEQ     M1_Ret
    PSHS    B
    LBSR    Put_Space
    PULS    B
    CMPB    #1
    LBNE    Put_Unite
    LDY     #MotEtUn
    LBRA    Put_Str
M1_Ret:
    RTS
M1_Soix:
    CMPB    #80
    BHS     M1_QV
    PSHS    B
    LDB     #6
    LDY     #MotDiz
    LBSR    Put_Mot
    LBSR    Put_Space
    PULS    B
    CMPB    #71
    BNE     M1_S2
    LDY     #MotEtOnze
    LBRA    Put_Str
M1_S2:
    SUBB    #60
    BRA     Moins_100
M1_QV:
    PSHS    B
    LDY     #MotQV
    LBSR    Put_Str
    PULS    B
    SUBB    #80
    BEQ     M1_Ret
    PSHS    B
    LBSR    Put_Space
    PULS    B
    LBRA    Moins_100

; -------------------------------------------------------------------
; 2-3. Mots -> phonèmes, groupes -> parole
; -------------------------------------------------------------------
Parse_Speak:
    LDX     #NormBuf
    CLR     GrN
PS_Loop:
    LDB     ,X
    BEQ     PS_Fin
    CMPB    #','
    BEQ     PS_Punct
    CMPB    #'.'
    BEQ     PS_Punct
    CMPB    #'?'
    BEQ     PS_Punct
    LBSR    Class_Of
    BITA    #C_LETTRE
    BNE     PS_Word
    LEAX    1,X
    BRA     PS_Loop
PS_Punct:
    STB     Ponct
    LEAX    1,X
    TST     GrN
    BEQ     PS_Loop
    PSHS    X
    JSR     Speak_Group
    PULS    X
    CLR     GrN
    BRA     PS_Loop
PS_Word:
    JSR     Word_Ph             ; X avance après le mot
    LDA     WordN
    BEQ     PS_Loop
    TST     GrN                 ; groupe trop long : on le dit d'abord
    BEQ     PS_Add
    ADDA    GrN
    CMPA    #MAX_PH
    BLS     PS_Add
    LDA     #','
    STA     Ponct
    PSHS    X
    JSR     Speak_Group
    PULS    X
    CLR     GrN
PS_Add:
    LDY     #WordPh
    LDB     WordN
    CMPB    #MAX_PH
    BLS     PS_A1
    LDB     #MAX_PH
PS_A1:
    PSHS    X
    LDX     #GrPh
    LDA     GrN                 ; GrN + B <= MAX_PH
    LEAX    A,X
PS_A2:
    LDA     ,Y+
    STA     ,X+
    INC     GrN
    DECB
    BNE     PS_A2
    PULS    X
    LBRA    PS_Loop
PS_Fin:
    TST     GrN
    BEQ     PS_Ret
    LDA     #'.'
    STA     Ponct
    JMP     Speak_Group
PS_Ret:
    RTS

; X = début d'un mot dans NormBuf -> WordPh, WordN ; X après le mot.
; Pour chaque position, la première règle de la lettre qui convient.
Word_Ph:
    CLR     WordN
WP_Loop:
    LDB     ,X
    LBSR    Class_Of
    BITA    #C_LETTRE
    BNE     WP_Lettre
    RTS
WP_Lettre:
    LDY     #RegIdx             ; règles de cette lettre
WP_Idx:
    LDA     ,Y
    BEQ     WP_Skip             ; aucune : on saute la lettre
    CMPB    ,Y
    BEQ     WP_Found
    LEAY    3,Y
    BRA     WP_Idx
WP_Skip:
    LEAX    1,X
    BRA     WP_Loop
WP_Found:
    LDY     1,Y
WP_Rule:
    LDA     ,Y
    CMPA    #$FF
    BEQ     WP_Skip
    ; découpe de la règle : gauche (à l'envers), lettres, droite, phonèmes
    LDB     ,Y+
    STB     RNL
    STY     RL
    LEAY    B,Y
    LDB     ,Y+
    STB     RNM
    STY     RM
    LEAY    B,Y
    LDB     ,Y+
    STB     RNR
    STY     RR
    LEAY    B,Y
    LDB     ,Y+
    STB     RNP
    STY     RP
    LEAY    B,Y
    STY     RNext
    ; lettres : égalité exacte
    LDY     RM
    CLRB
WP_M:
    CMPB    RNM
    BHS     WP_MOk
    LDA     B,X
    CMPA    B,Y
    BNE     WP_Non
    INCB
    BRA     WP_M
WP_MOk:
    ; contexte de droite, après les lettres
    STB     RIdx                ; = RNM
    CLR     RK
WP_R:
    LDB     RK
    CMPB    RNR
    BHS     WP_ROk
    LDY     RR
    LDA     B,Y                 ; motif
    ADDB    RIdx
    LDB     B,X                 ; texte
    JSR     Class_Ok
    BCS     WP_Non
    INC     RK
    BRA     WP_R
WP_ROk:
    ; contexte de gauche, en reculant depuis X-1
    CLR     RK
WP_L:
    LDB     RK
    CMPB    RNL
    BHS     WP_Oui
    LDY     RL
    LDA     B,Y
    NEGB
    DECB                        ; -1-k
    LDB     B,X
    JSR     Class_Ok
    BCS     WP_Non
    INC     RK
    BRA     WP_L
WP_Non:
    LDY     RNext
    LBRA    WP_Rule
WP_Oui:
    ; phonèmes de la règle -> WordPh
    LDY     RP
    LDB     RNP
    BEQ     WP_Avance
WP_P:
    LDA     WordN
    CMPA    #MAX_PH+8
    BHS     WP_PSkip
    PSHS    B,X
    LDX     #WordPh
    LDB     ,Y
    STB     A,X
    INC     WordN
    PULS    B,X
WP_PSkip:
    LEAY    1,Y
    DECB
    BNE     WP_P
WP_Avance:
    LDB     RNM
    ABX
    LBRA    WP_Loop

; A = motif, B = caractère du texte : C = 0 s'il convient.
;   ' ' bord (pas une lettre)   '#' voyelle   '^' consonne
;   '!' pas une voyelle         '+' e i y é è ê   autre : égalité
Class_Ok:
    CMPA    #$20
    BEQ     CO_Bord
    CMPA    #'#'
    BEQ     CO_Voy
    CMPA    #'^'
    BEQ     CO_Cons
    CMPA    #'!'
    BEQ     CO_NVoy
    CMPA    #'+'
    BEQ     CO_Avant
    PSHS    A
    CMPB    ,S+
    BEQ     CO_Oui
    BRA     CO_Non
CO_Bord:
    LBSR    Class_Of
    BITA    #C_LETTRE
    BEQ     CO_Oui
    BRA     CO_Non
CO_Voy:
    LBSR    Class_Of
    BITA    #C_VOY
    BNE     CO_Oui
    BRA     CO_Non
CO_Cons:
    LBSR    Class_Of
    BITA    #C_VOY
    BNE     CO_Non
    BITA    #C_LETTRE
    BNE     CO_Oui
    BRA     CO_Non
CO_NVoy:
    LBSR    Class_Of
    BITA    #C_VOY
    BEQ     CO_Oui
    BRA     CO_Non
CO_Avant:
    LBSR    Class_Of
    BITA    #C_AVANT
    BNE     CO_Oui
CO_Non:
    ORCC    #1
    RTS
CO_Oui:
    ANDCC   #$FE
    RTS

; -------------------------------------------------------------------
; Un groupe : afficher ses phonèmes, calculer ses trames, le dire
; -------------------------------------------------------------------
Speak_Group:
    LDX     #GrPh               ; symboles des phonèmes
    LDU     #Disp
    LDB     GrN
SG_Sym:
    PSHS    B
    LDA     ,X+
    JSR     Phon_Ptr            ; Y = PhonTbl + 16 x A
    LDA     PH_SYMB,Y
    STA     ,U+
    PULS    B
    DECB
    BNE     SG_Sym
    LDA     Ponct
    STA     ,U+
SG_Pad:
    CMPU    #Disp+IN_MAX+1
    BHS     SG_Aff
    LDA     #$20
    STA     ,U+
    BRA     SG_Pad
SG_Aff:
    CLR     ,U
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDX     #Disp
    LDA     #IN_X
    LDB     #PH_Y
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     Build_Frames
    JMP     Play

; A = phonème -> Y = sa ligne de PhonTbl. Détruit D.
Phon_Ptr:
    TFR     A,B
    CLRA
    LSLD
    LSLD
    LSLD
    LSLD
    ADDD    #PhonTbl
    TFR     D,Y
    RTS

; -------------------------------------------------------------------
; 4. Trames (groupes_en_trames() de parole.py)
; -------------------------------------------------------------------
Build_Frames:
    LDX     #FrBuf
    STX     FrPtr
    ; dernière voyelle (allongée de moitié) et durée totale
    LDA     #$FF
    STA     Der
    CLR     BK
BF_Der:
    LDB     BK
    CMPB    GrN
    BHS     BF_Tot
    LDX     #GrPh
    LDA     B,X
    BSR     Phon_Ptr
    LDA     PH_SORTE,Y
    CMPA    #K_V
    BNE     BF_DN
    LDB     BK
    STB     Der
BF_DN:
    INC     BK
    BRA     BF_Der
BF_Tot:
    LDD     #0
    STD     Total
    CLR     BK
BF_T:
    LDB     BK
    CMPB    GrN
    BHS     BF_Init
    LBSR    Phon_Dur            ; B = durée du phonème BK
    CLRA
    ADDD    Total
    STD     Total
    INC     BK
    BRA     BF_T
BF_Init:
    LDD     #0
    STD     Tt
    STD     Acc16
    LDB     Voix
    LDX     #VoixPer
    LDA     B,X
    STA     Pd
    CLR     PrevOk
    CLR     BK
BF_Ph:
    LDB     BK
    CMPB    GrN
    LBHS    BF_Pause
    LBSR    Phon_Dur
    STB     CurDur
    LDB     BK
    LDX     #GrPh
    LDA     B,X
    LBSR    Phon_Ptr
    LDD     PH_I1,Y             ; cible
    STD     CI1
    LDD     PH_I1+2,Y
    STD     CI2
    LDD     PH_I1+4,Y
    STD     CI3
    LDA     PH_A1,Y
    STA     CA1
    LDA     PH_A1+1,Y
    STA     CA2
    LDA     PH_A1+2,Y
    STA     CA3
    LDD     PH_MASQUE,Y
    STD     CMasque
    LDA     PH_VOISE,Y
    STA     CVoi
    LDA     PH_SORTE,Y
    CMPA    #K_P
    LBEQ    BF_Occl
    CLR     BF
BF_F:
    LDA     BF
    CMPA    CurDur
    LBHS    BF_PhFin
    TST     PrevOk
    BEQ     BF_Cible
    CMPA    #TRANS
    BHS     BF_Cible
    INCA                        ; k = f + 1
    STA     BKk
    LDX     #CI1                ; incréments : prev + ((c - prev) >> 2) x k
    LDY     #PI1
    LDU     #EI1
    LDA     #3
    STA     BCnt
BF_I:
    LDD     ,X++
    SUBD    ,Y
    ASRD
    ASRD
    STD     ITmp
    LDA     BKk
    STA     KCnt
    LDD     #0
BF_IK:
    ADDD    ITmp
    DEC     KCnt
    BNE     BF_IK
    ADDD    ,Y++
    STD     ,U++
    DEC     BCnt
    BNE     BF_I
    LDX     #CA1                ; amplitudes : prev + (((c - prev) x k) >> 2)
    LDY     #PA1
    LDU     #EA1
    LDB     #3
BF_A:
    PSHS    B
    LDA     ,X+
    SUBA    ,Y
    STA     ITmp
    CLRA
    LDB     BKk
BF_AK:
    ADDA    ITmp
    DECB
    BNE     BF_AK
    ASRA
    ASRA
    ADDA    ,Y+
    STA     ,U+
    PULS    B
    DECB
    BNE     BF_A
    BRA     BF_Emet
BF_Cible:
    LDD     CI1
    STD     EI1
    LDD     CI2
    STD     EI2
    LDD     CI3
    STD     EI3
    LDA     CA1
    STA     EA1
    LDA     CA2
    STA     EA2
    LDA     CA3
    STA     EA3
BF_Emet:
    LDD     CMasque
    STD     EMasque
    LDA     CVoi
    STA     EVoi
    JSR     Emit_Frame
    INC     BF
    LBRA    BF_F

; Occlusive : tenue (silence ou murmure) puis 2 trames d'explosion.
BF_Occl:
    LDA     CurDur
    SUBA    #2
    STA     BF
BF_Ten:
    TST     BF
    BEQ     BF_Expl
    LDD     #PH_I200
    STD     EI1
    LDD     CI2
    STD     EI2
    LDD     CI3
    STD     EI3
    CLR     EA1
    TST     CVoi
    BEQ     BF_T0
    LDA     #2
    STA     EA1
BF_T0:
    CLR     EA2
    CLR     EA3
    LDD     #0
    STD     EMasque
    LDA     CVoi
    STA     EVoi
    JSR     Emit_Frame
    DEC     BF
    BRA     BF_Ten
BF_Expl:
    LDA     #2
    STA     BF
BF_Ex:
    LDD     CI1
    STD     EI1
    LDD     CI2
    STD     EI2
    LDD     CI3
    STD     EI3
    LDA     CA1
    STA     EA1
    LDA     CA2
    STA     EA2
    LDA     CA3
    STA     EA3
    LDD     CMasque
    STD     EMasque
    CLR     EVoi
    JSR     Emit_Frame
    DEC     BF
    BNE     BF_Ex
BF_PhFin:
    LDD     CI1                 ; la cible devient le point de départ
    STD     PI1
    LDD     CI2
    STD     PI2
    LDD     CI3
    STD     PI3
    LDA     CA1
    STA     PA1
    LDA     CA2
    STA     PA2
    LDA     CA3
    STA     PA3
    LDA     #1
    STA     PrevOk
    INC     BK
    LBRA    BF_Ph

; Pause après le groupe : trames muettes.
BF_Pause:
    LDB     #PAUSE_VIRG
    LDA     Ponct
    CMPA    #','
    BEQ     BF_P1
    LDB     #PAUSE_POINT
BF_P1:
    LDX     FrPtr
BF_P2:
    CMPX    #FR_LIMITE
    BHI     BF_PFin
    PSHS    B
    LDD     #0
    STD     FR_I1,X
    STD     FR_I2,X
    STD     FR_I3,X
    STD     FR_MASQUE,X
    LDA     #SINAMP/256
    STA     FR_P1,X
    STA     FR_P2,X
    STA     FR_P3,X
    CLR     FR_PER,X
    LEAX    FR_TAILLE,X
    PULS    B
    DECB
    BNE     BF_P2
BF_PFin:
    STX     FrPtr
    RTS

; B = BK -> B = durée du phonème GrPh[BK], allongée de moitié si c'est la
; dernière voyelle. Détruit A, X, Y.
Phon_Dur:
    LDX     #GrPh
    LDA     B,X
    LBSR    Phon_Ptr
    LDB     PH_DUR,Y
    LDA     BK
    CMPA    Der
    BNE     PD_End
    TFR     B,A
    LSRA
    PSHS    A
    ADDB    ,S+
PD_End:
    RTS

; Une trame : EI1-3, EA1-3, EMasque, EVoi -> FrBuf ; avance la mélodie.
Emit_Frame:
    ; période : Pd, puis la fin de groupe sur les 24 dernières trames
    LDA     Pd
    STA     EPer
    LDD     Total
    SUBD    Tt                  ; r = Total - t
    CMPD    #24
    BHI     EF_Amp
    NEGB
    ADDB    #24                 ; q = 24 - r
    LDA     Ponct
    CMPA    #','
    BEQ     EF_Virg
    CMPA    #'?'
    BEQ     EF_Quest
    TFR     B,A                 ; '.' : P + (3q >> 3)
    ASLB
    PSHS    A
    ADDB    ,S+
    LSRB
    LSRB
    LSRB
    ADDB    EPer
    STB     EPer
    BRA     EF_Amp
EF_Virg:
    LSRB                        ; ',' : P - (q >> 3)
    LSRB
    LSRB
    BRA     EF_Sub
EF_Quest:
    TFR     B,A                 ; '?' : P - (3q >> 2)
    ASLB
    PSHS    A
    ADDB    ,S+
    LSRB
    LSRB
EF_Sub:
    PSHS    B
    LDA     EPer
    SUBA    ,S+
    STA     EPer
EF_Amp:
    ; amplitudes : somme <= 15 (on rogne A3, puis A2, puis A1)
EF_Clamp:
    LDA     EA1
    ADDA    EA2
    ADDA    EA3
    CMPA    #15
    BLS     EF_Ecrit
    TST     EA3
    BEQ     EF_C2
    DEC     EA3
    BRA     EF_Clamp
EF_C2:
    TST     EA2
    BEQ     EF_C1
    DEC     EA2
    BRA     EF_Clamp
EF_C1:
    DEC     EA1
    BRA     EF_Clamp
EF_Ecrit:
    LDX     FrPtr
    CMPX    #FR_LIMITE
    BHI     EF_Avance           ; tampon plein : la fin ne sera pas dite
    LDD     EMasque
    STD     FR_MASQUE,X
    LSRD
    STD     ITmp                ; moitié du masque : le souffle reste centré
    LDD     EI1
    SUBD    ITmp
    STD     FR_I1,X
    LDD     EI2
    SUBD    ITmp
    STD     FR_I2,X
    LDD     EI3
    SUBD    ITmp
    STD     FR_I3,X
    LDA     EA1
    ADDA    #SINAMP/256
    STA     FR_P1,X
    LDA     EA2
    ADDA    #SINAMP/256
    STA     FR_P2,X
    LDA     EA3
    ADDA    #SINAMP/256
    STA     FR_P3,X
    CLR     FR_PER,X
    TST     EVoi
    BEQ     EF_Sourd
    LDA     EPer
    STA     FR_PER,X
EF_Sourd:
    LEAX    FR_TAILLE,X
    STX     FrPtr
EF_Avance:
    ; t + 1 ; la voix descend de DECLIN sur le groupe (sans division)
    LDD     Tt
    ADDD    #1
    STD     Tt
    LDD     Acc16
    ADDD    #DECLIN
EF_Decl:
    CMPD    Total
    BLO     EF_DFin
    SUBD    Total
    INC     Pd
    BRA     EF_Decl
EF_DFin:
    STD     Acc16
    RTS

; -------------------------------------------------------------------
; 5. Lecture des trames : l'AY en convertisseur, le timer 3 en horloge
; -------------------------------------------------------------------
; SINAMP + a x 256 + i = signe(S) x ((a x |S| + 8) >> 4), S = S64[i]
Build_SinAmp:
    LDY     #SINAMP
    CLR     BK                  ; amplitude a
BS_A:
    LDX     #S64
    CLRB
BS_I:
    PSHS    B
    LDA     ,X+
    STA     ITmp                ; signe
    BPL     BS_Pos
    NEGA
BS_Pos:
    LDB     BK
    MUL                         ; D = a x |S|
    ADDD    #8
    LSRD
    LSRD
    LSRD
    LSRD
    TST     ITmp
    BPL     BS_Put
    NEGB
BS_Put:
    STB     ,Y+
    PULS    B
    INCB
    BNE     BS_I
    INC     BK
    LDA     BK
    CMPA    #16
    BLO     BS_A
    RTS

Ouvre_Dac:
    JSR     [VIS_TABLE+vis_Sound_Stop]
    ORCC    #%00010000          ; IRQ masquées jusqu'à Ferme_Dac
    LDA     #%10100010          ; CR2 : monocoup, E, O2 active ; bit 0 = 0 : CR3 en $A080
    STA     CR2
    LDA     #%00000010          ; CR3 : continu, E, sortie masquée, sans IRQ
    STA     CR3
    LDA     #%10100011          ; CR2 : idem, bit 0 = 1 : CR1 de nouveau en $A080
    STA     CR2
    LDD     #TICK
    STD     TIMER3
    LDY     #TabA               ; échantillon -> volumes (Play les garde)
    LDX     #TabC
    LDD     #$073F              ; AY : ni ton ni bruit, ports en entrée
    STD     AY_ADR              ;      (la sortie d'une voie = son volume)
    LDA     #MILIEU
    STA     Sample
    LDB     #MILIEU
    LDA     B,Y
    STA     VolA
    LDA     B,X
    STA     VolC
    LDA     #8
    LDB     VolA
    STD     AY_ADR
    LDA     #10
    LDB     VolC
    STD     AY_ADR
    RTS

; Volumes de l'AY à 0 ; comme init_audio : timers à 0, O2 et O3 en
; continu, CR1 adressé.
Ferme_Dac:
    LDD     #$0800
    STD     AY_ADR
    LDD     #$0A00
    STD     AY_ADR
    LDD     #0
    STD     TIMER2
    STD     TIMER3
    LDA     #%00000000          ; CR2 : CR3 en $A080
    STA     CR2
    LDA     #%10000010          ; CR3 : O3 active, continu, E
    STA     CR3
    LDA     #%10000011          ; CR2 : O2 active, continu, E, CR1 en $A080
    STA     CR2
    ANDCC   #%11101111
    RTS

; Trame U -> opérandes de la boucle. Détruit D.
Load_Frame:
    LDD     FR_I1,U
    STD     P_I1+1
    LDD     FR_I2,U
    STD     P_I2+1
    LDD     FR_I3,U
    STD     P_I3+1
    LDD     FR_MASQUE,U
    STD     P_Mask+2            ; ANDD # : 2 octets d'opcode
    LDA     FR_P1,U
    STA     P_T1+1              ; LDA étendu : poids fort de l'adresse
    LDA     FR_P2,U
    STA     P_T2+1
    LDA     FR_P3,U
    STA     P_T3+1
    LDA     FR_PER,U
    STA     CurPer
    RTS

; Dit les trames FrBuf..FrPtr. Modèle : synthese() de parole.py.
; Budget : 128 cycles par tranche, deux tranches par échantillon.
; Y = TabA et X = TabC pendant toute la lecture (posés par Ouvre_Dac).
Play:
    LDX     FrPtr
    CMPX    #FrBuf
    LBEQ    P_Ret
    JSR     Ouvre_Dac           ; pose Y = TabA, X = TabC
    LDD     #0
    STD     Ph1
    STD     Ph2
    STD     Ph3
    LDD     #GRAINE
    STD     Seed
    LDA     #1
    STA     PitchC
    LDU     #FrBuf
    BSR     Load_Frame
    LDA     #TRAME
    STA     FrameC
P_Loop:
    ; --- tranche A : volumes de l'échantillon, voix, hasard, formant 1 ---
PA_W:
    LDA     STATUS
    BITA    #$04
    BEQ     PA_W
    LDD     TIMER3              ; efface le drapeau du timer 3
    LDB     Sample
    LDA     B,Y
    STA     VolA
    LDA     B,X
    STA     VolC
    DEC     PitchC
    BNE     P_Rand
    LDA     CurPer
    BEQ     P_Sourd
    STA     PitchC              ; coup de glotte : formants remis en phase
    LDD     #0
    STD     Ph1
    STD     Ph2
    STD     Ph3
    BRA     P_Rand
P_Sourd:
    LDA     #64
    STA     PitchC
P_Rand:
    LDD     Seed                ; x <- 5x + 13849
    LSLD
    LSLD
    ADDD    Seed
    ADDD    #13849
    STD     Seed
P_Mask:
    ANDD    #$0000              ; masque du souffle (réécrit)
    STD     Jit
    LDD     Ph1
P_I1:
    ADDD    #$0000              ; incrément F1 (réécrit)
    ADDD    Jit
    STD     Ph1
    STA     P_T1+2
P_T1:
    LDA     >SINAMP             ; page = amplitude (réécrite), octet = phase
    STA     AccS
    ; --- tranche B : l'échantillon sort, formants 2 et 3, le suivant ---
PB_W:
    LDA     STATUS
    BITA    #$04
    BEQ     PB_W
    LDD     TIMER3
    LDA     #8
    LDB     VolA
    STD     AY_ADR              ; R8 = volume de A
    LDA     #10
    LDB     VolC
    STD     AY_ADR              ; R10 = volume de C
    LDD     Ph2
P_I2:
    ADDD    #$0000
    ADDD    Jit
    STD     Ph2
    STA     P_T2+2
P_T2:
    LDA     >SINAMP
    ADDA    AccS
    STA     AccS
    LDD     Ph3
P_I3:
    ADDD    #$0000
    ADDD    Jit
    STD     Ph3
    STA     P_T3+2
P_T3:
    LDA     >SINAMP
    ADDA    AccS
    ADDA    #MILIEU
    STA     Sample
    DEC     FrameC
    LBNE    P_Loop
    ; --- trame suivante : un échantillon tenu pendant le chargement ---
    LEAU    FR_TAILLE,U
    CMPU    FrPtr
    BHS     P_Fin
PC_W1:
    LDA     STATUS
    BITA    #$04
    BEQ     PC_W1
    LDD     TIMER3
    LDB     Sample
    LDA     B,Y
    STA     VolA
    LDA     B,X
    STA     VolC
    JSR     Load_Frame
PC_W2:
    LDA     STATUS
    BITA    #$04
    BEQ     PC_W2
    LDD     TIMER3
    LDA     #8
    LDB     VolA
    STD     AY_ADR
    LDA     #10
    LDB     VolC
    STD     AY_ADR
    LDA     #TRAME
    STA     FrameC
    LBRA    P_Loop
P_Fin:
    JMP     Ferme_Dac
P_Ret:
    RTS

; Phonèmes, règles, mots, classes, sinus : générés (tools/parole/parole.py)
    include "parole_data.inc"

; -------------------------------------------------------------------
; Données
; -------------------------------------------------------------------
TxtTitre:       FCN " PAROLE "
TxtVisVieux:    FCN "OSM-VISION trop ancien pour PAROLE."
TxtAide1:
    FCC     "Tapez une phrase, puis Entr"
    FCB     $82
    FCN     "e : OSM39 la dit."
TxtAide2:       FCN "Tab : voix      Echap : retour"
TxtPrepare:     FCC "Pr"            ; accents : codes de la police (page 437)
                FCB $82
                FCN "paration des tables...   "
TxtPret:        FCC "Pr"
                FCB $88
                FCN "t.                       "
TxtParle:       FCC "Je parle (IRQ masqu"
                FCB $82
                FCN "es)...   "
VoixNoms:       FDB TxtV0,TxtV1,TxtV2
TxtV0:          FCN "Voix : normale"
TxtV1:          FCN "Voix : grave  "
TxtV2:          FCC "Voix : aigu"
                FCB $89
                FCN " "
VoixPer:        FCB 62,74,44            ; période de départ (116, 97, 164 Hz)
; Latin-1 -> CP437 (police de la page 0)
Cp437Tbl:
    FCB     $E0,$85,$E2,$83,$E7,$87,$E8,$8A,$E9,$82,$EA,$88,$EB,$89
    FCB     $EE,$8C,$EF,$8B,$F4,$93,$F9,$97,$FB,$96,$FC,$81,0

; --- Variables ---
Voix            rmb 1
InLen           rmb 1
InBuf           rmb IN_MAX
InEnd           rmb 2
Disp            rmb IN_MAX+2
WStart          rmb 2
WEnd            rmb 2
WLen            rmb 1
WMaj            rmb 1
WMajVoy         rmb 1
NTmp            rmb 2
NMil            rmb 1
NRest           rmb 1
NDiz            rmb 1
Ponct           rmb 1
GrN             rmb 1
GrPh            rmb MAX_PH*2
WordN           rmb 1
WordPh          rmb MAX_PH+8
RNL             rmb 1           ; règle découpée
RL              rmb 2
RNM             rmb 1
RM              rmb 2
RNR             rmb 1
RR              rmb 2
RNP             rmb 1
RP              rmb 2
RNext           rmb 2
RIdx            rmb 1
RK              rmb 1
Der             rmb 1           ; dernière voyelle du groupe ($FF : aucune)
BK              rmb 1           ; phonème en cours
BF              rmb 1           ; trame dans le phonème
BKk             rmb 1
BCnt            rmb 1
KCnt            rmb 1
CurDur          rmb 1
Total           rmb 2
Tt              rmb 2
Acc16           rmb 2
Pd              rmb 1
PrevOk          rmb 1
CI1             rmb 2           ; cible (dans cet ordre)
CI2             rmb 2
CI3             rmb 2
CA1             rmb 1
CA2             rmb 1
CA3             rmb 1
PI1             rmb 2           ; précédente (dans cet ordre)
PI2             rmb 2
PI3             rmb 2
PA1             rmb 1
PA2             rmb 1
PA3             rmb 1
EI1             rmb 2           ; trame émise (dans cet ordre)
EI2             rmb 2
EI3             rmb 2
EA1             rmb 1
EA2             rmb 1
EA3             rmb 1
CMasque         rmb 2
CVoi            rmb 1
EMasque         rmb 2
EVoi            rmb 1
EPer            rmb 1
ITmp            rmb 2
FrPtr           rmb 2
Sample          rmb 1           ; échantillon 0..120
VolA            rmb 1           ; ses volumes sur les voies A et C
VolC            rmb 1
Seed            rmb 2
Jit             rmb 2
Ph1             rmb 2
Ph2             rmb 2
Ph3             rmb 2
PitchC          rmb 1
FrameC          rmb 1
CurPer          rmb 1
AccS            rmb 1
NormBuf         rmb NORM_MAX
; Les services d'affichage (lib/vis.inc) : l'application tourne dans sa
; propre page et emporte sa copie (OSM-VISION, en page 0, ne se voit pas).
; AVANT FrBuf : les trames s'écrivent au-delà de la fin du binaire.
    include "../lib/vision.asm"
FrBuf           equ *           ; trames jusqu'à SINAMP (FR_LIMITE)

