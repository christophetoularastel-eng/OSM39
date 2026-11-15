; ===================================================================
; NEIGE.ASM - Où tombe la fenêtre de retour de trame ? (banc sur carte)
; Usage: NEIGE
; Charge: page 1, $0000
;
; Un accès du processeur à la VRAM pendant l'affichage laisse une trace à
; l'écran (la « neige ») ; pendant le retour de trame, rien. Les programmes
; écrivent la VRAM juste après le signal de trame (IRQ du 68B40 : VSYNC sur
; son entrée C1) : cette fenêtre doit les contenir.
; NEIGE remplit l'écran de blanc, masque les interruptions et guette
; lui-même le signal de trame (bit 0 du registre d'état du 68B40, celui de
; l'IRQ du BIOS). Il mesure une trame en tours de boucle, puis, à chaque
; trame, attend « retard » lignes (une ligne VGA = 31,78 µs, 525 par
; trame) et lit 64 fois la VRAM (~10 lignes) : une bande sombre apparaît
; à la hauteur balayée à ce moment, si ce n'est plus le retour de trame.
;   Haut / Bas : retard - 1 / + 1 ligne
;   Page préc. / Page suiv. : - 10 / + 10 lignes
;   A / B / C / D : la boucle d'attente du signal (voir Attente)
;   Échap : fin
; Lecture : le plus petit retard qui fait apparaître la bande en haut de
; l'écran = la longueur de la fenêtre après le signal.
; Les deux cartes (v4, mono) : adresses de VRAM_* (hardware.inc).
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

LIGNES_TRAME    equ 525             ; lignes VGA par trame (R4, R5 du 6845)
LIGNE_CNS       equ 3178            ; une ligne = 31,78 µs (x 100)
SALVE           equ 64              ; lectures de la VRAM par trame
ATTR_FOND       equ $07             ; blanc sur noir : la neige y est sombre
ATTR_NUM        equ $78             ; noir (D3 : jamais le premier plan 0) sur blanc
ATTR_INFO       equ $1F             ; blanc sur bleu
CAR_PLEIN       equ $DB             ; pavé plein (page 0 de la police)
KEY_UP          equ $80
KEY_DOWN        equ $81
KEY_PGUP        equ $86
KEY_PGDN        equ $87

    section .code

Start:
    ORCC    #%01010000          ; IRQ et FIRQ masquées jusqu'à la fin
    CLR     VRAM_CTRL           ; page vidéo 0 (mono : GRAPH = 0)
    LDA     #10                 ; curseur caché
    STA     CRTC_RS
    LDA     #$2D
    STA     CRTC_DATA
    LDD     #$FFFF              ; départ de l'écran comme OSM-VISION
    LDB     #12
    STB     CRTC_RS
    STA     CRTC_DATA
    LDB     #13
    STB     CRTC_RS
    STA     CRTC_DATA

    LDX     #VRAM_BASE          ; tout le plan : pavés blancs
    LDA     #CAR_PLEIN
    LDB     #ATTR_FOND
St_Fond:
    STA     ,X
    STB     VRAM_COL_OFS,X
    LEAX    VRAM_PAS,X
    CMPX    #VRAM_END
    BLO     St_Fond

    CLR     Rang                ; les numéros des rangées 0-29, colonnes 0-1
St_Num:
    LDA     Rang
    LDB     #10
    JSR     Div8                ; A = dizaines, B = unités
    ADDA    #'0'
    ADDB    #'0'
    STD     NumTxt
    LDX     #NumTxt
    LDA     Rang
    CLRB
    LDE     #ATTR_NUM
    JSR     Ecrit
    INC     Rang
    LDA     Rang
    CMPA    #30
    BLO     St_Num

    LDX     #Txt2               ; les lignes d'aide
    LDD     #$0E06
    LDE     #ATTR_INFO
    JSR     Ecrit
    LDX     #Txt4
    LDD     #$1006
    LDE     #ATTR_INFO
    JSR     Ecrit

    LDX     #Signal             ; Signal recopié en RAM système (mode B, C)
    LDY     #gfx_tampon
St_Copie:
    LDA     ,X+
    STA     ,Y+
    CMPX    #Signal_Fin
    BLO     St_Copie
    LDX     #Boucle4000         ; la boucle du mode D, recopiée en $4000
    LDY     #$4000
St_Copie4:
    LDA     ,X+
    STA     ,Y+
    CMPX    #Boucle4000_Fin
    BLO     St_Copie4
    LDA     #'A'
    STA     Mode
    JSR     Mesure              ; une trame en tours de boucle -> Tours
    CLR     Retard
    CLR     Retard+1
    JSR     Calcule             ; Retard -> Iter, et la ligne d'état

; --- chaque trame : signal, retard, salve de lectures, clavier ---
Boucle:
    JSR     Attente
    LDX     Iter
    BEQ     Bo_Salve
Bo_Attente:                     ; mêmes instructions que la boucle de Mesure
    LDA     STATUS
    BITA    #1
    LEAX    -1,X
    BNE     Bo_Attente
Bo_Salve:
    LDB     #SALVE
Bo_Lit:
    LDA     VRAM_BASE           ; une lecture de la VRAM : la trace
    DECB
    BNE     Bo_Lit
    JSR     [table_function_ram+sys_kbd_poll]
    TSTA
    BEQ     Boucle
    CMPA    #$1B
    BEQ     Fin
    ANDA    #$DF                ; a, b, c -> A, B, C
    CMPA    #'A'
    BLO     Bo_Fleche
    CMPA    #'D'
    BHI     Bo_Fleche
    STA     Mode
    JSR     Calcule
    BRA     Boucle
Bo_Fleche:                      ; (les flèches $80-$87 : bit 5 déjà à 0)
    LDX     #-1
    CMPA    #KEY_UP
    BEQ     Bo_Pas
    LDX     #1
    CMPA    #KEY_DOWN
    BEQ     Bo_Pas
    LDX     #-10
    CMPA    #KEY_PGUP
    BEQ     Bo_Pas
    LDX     #10
    CMPA    #KEY_PGDN
    BNE     Boucle
Bo_Pas:
    TFR     X,D
    ADDD    Retard
    BPL     Bo_Haut
    CLRA                        ; pas sous 0
    CLRB
Bo_Haut:
    CMPD    #LIGNES_TRAME-1
    BLS     Bo_Pose
    LDD     #LIGNES_TRAME-1
Bo_Pose:
    STD     Retard
    JSR     Calcule
    BRA     Boucle

Fin:
    LDA     STATUS              ; le drapeau effacé : pas d'IRQ en attente
    LDX     TIMER1
    ANDCC   #%10101111          ; IRQ et FIRQ rétablies
    LDA     #$0C                ; écran ou fenêtre du Terminal effacés
    JMP     [table_function_ram+sys_PrintChar]

; -------------------------------------------------------------------
; Attente du signal de trame, selon Mode (quel accès perturbe l'image ?) :
;   A : la boucle tourne en RAM page 1 et lit le 68B40 ($A081)
;   B : la même, recopiée en RAM système (gfx_tampon) : lit le 68B40
;   C : 3/4 de la trame à lire un octet de RAM page 1 (aucune
;       entrée-sortie), puis l'attente de B
;   D : comme C, mais la boucle et l'octet lu sont en $4000 (A14 = 1) :
;       au retour d'une adresse haute ($FFFF des cycles morts), U106
;       (validé par A15 à travers un inverseur) ne peut plus voir
;       $8000-$9FFF un instant, puisque A14 reste à 1
Attente:
    LDA     Mode
    CMPA    #'A'
    BEQ     Signal
    CMPA    #'B'
    LBEQ    gfx_tampon
    LDX     Tours               ; C, D : 3/4 de la trame en lectures de RAM
    TFR     X,D
    LSRA
    RORB
    LSRA
    RORB                        ; D = Tours / 4
    PSHS    D
    TFR     X,D
    SUBD    ,S++                ; D = 3/4 de la trame (et un peu plus :
    TFR     D,X                 ; la salve et le clavier sont passés)
    LDA     Mode
    CMPA    #'D'
    BNE     At_Ram
    JSR     $4000               ; D : la même boucle, en $4000
    JMP     gfx_tampon
At_Ram:                         ; mêmes instructions que Bo_Attente, sans E/S
    LDA     Leurre
    BITA    #1
    LEAX    -1,X
    BNE     At_Ram
    JMP     gfx_tampon

; Boucle4000 : recopiée en $4000 ; X tours, lit $4020 (mêmes instructions
; que At_Ram). Adresses absolues : elle ne tourne qu'en $4000.
Boucle4000:
    FCB     $B6,$40,$20         ; LDA $4020
    FCB     $85,$01             ; BITA #1
    FCB     $30,$1F             ; LEAX -1,X
    FCB     $26,$F7             ; BNE (au LDA)
    FCB     $39                 ; RTS
Boucle4000_Fin:

; Signal : attend le drapeau du timer 1 (le signal de trame) et l'efface.
; Détruit A, X. Indépendant de sa place : recopié en RAM système.
Signal:
    LDA     STATUS
    BITA    #1
    BEQ     Signal
    LDX     TIMER1              ; lecture du compteur : drapeau effacé
    RTS
Signal_Fin:

; Mesure : Tours = tours de la boucle d'attente pendant une trame (la
; dernière de quatre).
Mesure:
    LDB     #4
Me_Trame:
    PSHS    B
    BSR     Signal
    LDX     #0
Me_Tour:                        ; mêmes instructions que Bo_Attente
    LEAX    1,X
    LDA     STATUS
    BITA    #1
    BEQ     Me_Tour
    STX     Tours
    LDX     TIMER1
    PULS    B
    DECB
    BNE     Me_Trame
    RTS

; Calcule : Iter = Retard x Tours / 525 ; la ligne d'état (rangée 13).
Calcule:
    LDD     Retard
    MULD    Tours               ; Q = Retard x Tours
    DIVQ    #LIGNES_TRAME       ; W = quotient
    STW     Iter
    LDY     #EtatNum            ; « retard   ddddd lignes »
    LDD     Retard
    JSR     Dec5
    LDD     Retard              ; « = ddddd µs »
    MULD    #LIGNE_CNS
    DIVQ    #100
    TFR     W,D
    LDY     #EtatUs
    JSR     Dec5
    LDD     Tours               ; « trame = ddddd tours »
    LDY     #EtatTours
    JSR     Dec5
    LDX     #Txt1
    LDD     #$0D02
    LDE     #ATTR_INFO
    JSR     Ecrit
    LDA     Mode                ; « mode X : ... »
    STA     TxtMode+6
    SUBA    #'A'
    LDB     #TXT_MODE_L
    MUL
    ADDD    #TxtModes
    TFR     D,X
    LDY     #TxtMode+10
Ca_Copie:
    LDA     ,X+
    STA     ,Y+
    CMPY    #TxtMode+10+TXT_MODE_L
    BLO     Ca_Copie
    LDX     #TxtMode
    LDD     #$1202
    LDE     #ATTR_INFO
    JMP     Ecrit

; Ecrit : X = texte (0 final), A = rangée, B = colonne, E = attribut.
; Détruit D, X, Y.
Ecrit:
    PSHS    B
    LDB     #80
    MUL                         ; D = rangée x 80
    ADDB    ,S+
    ADCA    #0
    IFNE    CARTE_MONO
    LSLB                        ; mono : deux octets par case
    ROLA
    ENDC
    ADDD    #VRAM_BASE
    TFR     D,Y
Ec_Car:
    LDA     ,X+
    BEQ     Ec_Fin
    STA     ,Y
    STE     VRAM_COL_OFS,Y
    LEAY    VRAM_PAS,Y
    BRA     Ec_Car
Ec_Fin:
    RTS

; Div8 : A / B -> A = quotient, B = reste (A < 256, B > 0)
Div8:
    PSHS    B
    TFR     A,B
    CLRA
Dv_Boucle:
    CMPB    ,S
    BLO     Dv_Fin
    SUBB    ,S
    INCA
    BRA     Dv_Boucle
Dv_Fin:
    LEAS    1,S
    RTS

; Dec5 : D -> 5 caractères à ,Y (zéros de tête en espaces). Détruit D, X, Y.
Dec5:
    LDX     #Puiss
    CLR     Vu
De_Rang:
    PSHS    D
    LDA     #'0'
    STA     Chiffre
    PULS    D
De_Sous:
    CMPD    ,X
    BLO     De_Pose
    SUBD    ,X
    INC     Chiffre
    BRA     De_Sous
De_Pose:
    PSHS    D
    LDA     Chiffre
    CMPX    #Puiss+8            ; les unités : toujours écrites
    BEQ     De_Ecrit
    CMPA    #'0'
    BNE     De_Vu
    TST     Vu
    BNE     De_Ecrit
    LDA     #' '
    BRA     De_Ecrit
De_Vu:
    INC     Vu
De_Ecrit:
    STA     ,Y+
    PULS    D
    LEAX    2,X
    CMPX    #Puiss+10
    BLO     De_Rang
    RTS

Puiss:      FDB     10000,1000,100,10,1

Txt1:       FCC     " NEIGE   retard "
EtatNum:    FCC     "00000 lignes = "
EtatUs:     FCC     "00000 us apres le signal   trame = "
EtatTours:  FCC     "00000 tours "
            FCB     0
Txt2:       FCN     " Haut/Bas : 1 ligne   Page prec./suiv. : 10 lignes   Echap : fin "
Txt4:       FCN     " Bande sombre en haut : la fenetre de retour de trame est finie "
TXT_MODE_L  equ     58
TxtMode:    FCC     " mode A : "
            RMB     TXT_MODE_L
            FCB     0
TxtModes:   FCC     "attente en RAM page 1, lit le 68B40 ($A081)               "
            FCC     "attente en RAM systeme ($CA2F), lit le 68B40 ($A081)      "
            FCC     "lit la RAM page 1 (3/4 de trame), puis attente comme B    "
            FCC     "comme C, mais la boucle et l'octet lu sont en $4000       "

NumTxt:     FCB     0,0,0
Rang:       RMB     1
Retard:     RMB     2
Tours:      RMB     2
Iter:       RMB     2
Vu:         RMB     1
Chiffre:    RMB     1
Mode:       RMB     1
Leurre:     FCB     0
