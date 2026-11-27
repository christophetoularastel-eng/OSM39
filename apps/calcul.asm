; ===================================================================
; CALCUL.ASM - La calculatrice de poche, accessoire d'OSM-VISION
; ===================================================================
; Une fenêtre sur le bureau (touche = d'OSM-VISION, ou son menu Espace) ;
; Échap la ferme (RTS : OSM-VISION rend l'écran qu'elle recouvrait).
; Le modèle exact est tools/calcul/calcul.py : les règles (nombres,
; arrondi, enchaînement des touches, affichage) y sont écrites ; ce
; programme fait la même chose, test/verifie_calcul.py le prouve.
;
; Les nombres : décimaux exacts, au plus 12 chiffres significatifs et 11
; décimales, moins de 10^12. Un nombre = NB octets : le signe (0 : +, 1 :
; -, jamais - pour zéro), puis ND chiffres (0-9, un par octet), le chiffre
; d'indice p valant 10^(12-p) (indice 0 = 10^12, toujours 0 ; 12 = les
; unités ; 23 = 10^-11).
; Un calcul pose son résultat exact (ou assez de chiffres exacts) dans le
; tampon T (TL chiffres, T[i] vaut 10^(23-i) : le chiffre p d'un nombre
; est T[11+p], 10^-12 est T[35]) puis Arrondir le garde : 12 chiffres
; significatifs au plus, pas plus bas que 10^-11, arrondi au plus proche
; (la moitié en s'éloignant de zéro : il suffit du chiffre suivant, exact),
; Erreur à 10^12 ou plus.
;   Addition   : exacte, signes comparés (|a| - |b|) ;
;   Multiplie  : produit exact (46 chiffres), Decal = 2 divise par 100 (%) ;
;   Divise     : division longue, 36 chiffres de quotient (jusqu'à 10^-12) ;
;   Racine     : chiffre par chiffre (soustraction des impairs 20P+1,
;                20P+3...), 19 chiffres (jusqu'à 10^-12).
;
; Le clavier de la calculatrice : 25 touches (5 x 5, indices 0-24) ; le
; clavier du PC en choisit une (TabCles) et l'appuie, le joystick
; (lib/joy.asm, Joy_Evts) déplace la sélection, son bouton l'appuie.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"
    include "../lib/ui.inc"
    include "../lib/vis.inc"

    export App_Start

VIS_REQUIS      equ (vis_Ligne/2)+1

WIN_X           equ 25              ; fenêtre 30 x 17 (ombre en plus)
WIN_Y           equ 4
WIN_W           equ 30
WIN_H           equ 17
LARGE           equ WIN_W-2         ; cases intérieures composées par rangée
R_LCD           equ 2               ; rangées (depuis le haut de la fenêtre)
R_TOUCHES       equ 4               ; 4, 6, 8, 10, 12
R_AIDE          equ 14              ; 14, 15
A_LCD           equ $28             ; noir sur vert (écran à cristaux)
A_AIDE          equ COLOR_TEXT
A_SEL           equ $68             ; la touche sélectionnée : noir sur jaune
A_CHIFFRE       equ $17
A_OPER          equ $47
A_FONC          equ $27
C_DIV           equ $F6             ; ÷ ± (CP437 ; le $FB de notre police
C_PM            equ $F1             ; n'est pas un √ : la touche dit « Rac »)

NB              equ 25              ; un nombre : signe + ND chiffres
ND              equ 24
TL              equ 48              ; le tampon T
RL              equ 24              ; Racine : reste, racine partielle, 20P+1

; les touches (indices)
T_MC            equ 0
T_EFF           equ 4
T_EGAL          equ 24

    section .code

; -------------------------------------------------------------------
; Point d'entrée (offset 0), IRQ actives
; -------------------------------------------------------------------
App_Start:
    ANDCC   #%11101111
    LDA     >VIS_COUNT_ADR
    CMPA    #VIS_REQUIS
    BHS     AS_Ok
    RTS
AS_Ok:
    JSR     Joy_Init
    JSR     Remise
    LDX     #Mem
    JSR     Zero
    LDA     #T_EGAL
    STA     Sel
    JSR     Dessine_Tout

Boucle:
    JSR     [table_function_ram+sys_kbd_poll]
    TSTA
    BNE     Clavier
    LDE     #1
    JSR     [table_function_ram+sys_video_wait_vsync]
    JSR     Joy_Evts
    BEQ     Boucle
    JSR     Manette
    BRA     Boucle

Clavier:
    CMPA    #$1B                    ; Échap : retour à OSM-VISION
    BEQ     Fin
    LDX     #TabCles
Cl_Cherche:
    LDB     ,X
    BEQ     Boucle                  ; touche inconnue
    CMPA    ,X++
    BNE     Cl_Cherche
    LDB     -1,X
    LDA     Sel
    STA     AncSel
    STB     Sel
    JSR     Appuie
    JSR     Redessine
    BRA     Boucle
Fin:
    RTS

; Manette : A = événements de Joy_Evts : un pas (haut, bas, gauche,
; droite, bornés), puis le bouton appuie la touche sélectionnée.
Manette:
    STA     Evts
    LDA     Sel
    STA     AncSel
    JSR     Lig_Col                 ; LigS, ColS
    LDA     Evts
    BITA    #JOY_HAUT
    BEQ     Ma_1
    TST     LigS
    BEQ     Ma_1
    DEC     LigS
Ma_1:
    BITA    #JOY_BAS
    BEQ     Ma_2
    LDB     LigS
    CMPB    #4
    BHS     Ma_2
    INC     LigS
Ma_2:
    BITA    #JOY_GAUCHE
    BEQ     Ma_3
    TST     ColS
    BEQ     Ma_3
    DEC     ColS
Ma_3:
    BITA    #JOY_DROITE
    BEQ     Ma_4
    LDB     ColS
    CMPB    #4
    BHS     Ma_4
    INC     ColS
Ma_4:
    LDA     LigS
    LDB     #5
    MUL
    ADDB    ColS
    STB     Sel
    LDA     Evts
    BITA    #JOY_BOUTON
    BEQ     Ma_Fin
    LDB     Sel
    JSR     Appuie
Ma_Fin:
    JMP     Redessine

; Lig_Col : Sel -> LigS = Sel / 5, ColS = Sel mod 5
Lig_Col:
    LDA     Sel
    CLRB
LC_B:
    CMPA    #5
    BLO     LC_F
    SUBA    #5
    INCB
    BRA     LC_B
LC_F:
    STA     ColS
    STB     LigS
    RTS

; ===================================================================
; LES TOUCHES : Appuie, B = indice
; ===================================================================
Appuie:
    STB     Tch
    CMPB    #T_EFF
    BEQ     Remise                  ; C : tout sauf la mémoire
    TST     Err
    BNE     Ap_Rien
    LDX     #TabActions
    ASLB
    JMP     [B,X]
Ap_Rien:
    RTS

Remise:
    LDX     #Acc
    JSR     Zero
    LDX     #Xv
    JSR     Zero
    CLR     Op
    CLR     DernOp
    CLR     Err
    CLR     Saisie
    RTS

Erreur:
    LDA     #1
    STA     Err
    CLR     Op
    CLR     Saisie
    RTS

; --- la saisie ---
Debut_Saisie:
    TST     Saisie
    BNE     DS_Fin
    LDA     #1
    STA     Saisie
    CLR     EEntN
    CLR     EDecN
    CLR     EPt
    CLR     ENeg
DS_Fin:
    RTS

Ac_Chiffre:
    BSR     Debut_Saisie
    LDA     EEntN
    ADDA    EDecN
    CMPA    #12
    BHS     Ac_Val
    LDB     Tch
    LDX     #ValCh
    LDA     B,X                     ; A = le chiffre
    TST     EPt
    BEQ     Ch_Ent
    LDB     EDecN
    CMPB    #11
    BHS     Ac_Val
    LDX     #EDec
    ABX
    STA     ,X
    INC     EDecN
    BRA     Ac_Val
Ch_Ent:
    TST     EEntN
    BNE     Ch_Pose
    TSTA
    BEQ     Ac_Val                  ; un zéro en tête : rien
Ch_Pose:
    LDX     #EEnt
    LDB     EEntN
    ABX
    STA     ,X
    INC     EEntN
Ac_Val:
    JMP     Valeur_Saisie

Ac_Point:
    BSR     Debut_Saisie
    LDA     #1
    STA     EPt
    JMP     Valeur_Saisie

Ac_Ret:
    TST     Saisie
    LBEQ    Ap_Rien
    TST     EDecN
    BEQ     Re_1
    DEC     EDecN
    BRA     Ac_Val
Re_1:
    TST     EPt
    BEQ     Re_2
    CLR     EPt
    BRA     Ac_Val
Re_2:
    TST     EEntN
    BEQ     Ac_Val
    DEC     EEntN
    BRA     Ac_Val

Ac_PM:
    TST     Saisie
    BEQ     PM_Res
    LDA     ENeg
    EORA    #1
    STA     ENeg
    BRA     Ac_Val
PM_Res:
    LDX     #Xv
    JMP     Negue

; Valeur_Saisie : Xv = le nombre tapé (exact : 12 chiffres, 11 décimales)
Valeur_Saisie:
    LDX     #Xv
    JSR     Zero
    LDB     EEntN                   ; chiffre i de n : indice 13 - n + i
    BEQ     VS_Dec
    LDX     #Xv+14
    NEGB
    LEAX    B,X
    LDY     #EEnt
    LDB     EEntN
VS_E:
    LDA     ,Y+
    STA     ,X+
    DECB
    BNE     VS_E
VS_Dec:
    LDB     EDecN                   ; décimale j : indice 13 + j
    BEQ     VS_Signe
    LDX     #Xv+14
    LDY     #EDec
VS_D:
    LDA     ,Y+
    STA     ,X+
    DECB
    BNE     VS_D
VS_Signe:
    TST     ENeg
    BEQ     VS_Fin
    LDX     #Xv
    JSR     EstNul
    BEQ     VS_Fin
    LDA     #1
    STA     Xv
VS_Fin:
    RTS

; --- + - x ÷ ---
Ac_Oper:
    LDB     Tch
    LDX     #OpCode
    LDA     B,X
    STA     NouvOp
    TST     Op
    BEQ     AO_Pas
    TST     Saisie
    BEQ     AO_Pose                 ; deux opérateurs de suite : le second
    LDX     #Acc
    LDY     #OpA
    JSR     Copie
    LDX     #Xv
    LDY     #OpB
    JSR     Copie
    LDA     Op
    JSR     Opere
    LBCS    Erreur
    LDX     #Res
    LDY     #Acc
    JSR     Copie
    LDX     #Res
    LDY     #Xv
    JSR     Copie
    BRA     AO_Pose
AO_Pas:
    LDX     #Xv
    LDY     #Acc
    JSR     Copie
AO_Pose:
    LDA     NouvOp
    STA     Op
    CLR     Saisie
    RTS

; --- = ---
Ac_Egal:
    TST     Op
    BEQ     AE_Dern
    LDX     #Xv
    LDY     #DernB
    JSR     Copie
    LDA     Op
    STA     DernOp
    LDX     #Acc
    LDY     #OpA
    JSR     Copie
    LDX     #Xv
    LDY     #OpB
    JSR     Copie
    LDA     Op
    CLR     Op
    JSR     Opere
    BRA     AE_Fin
AE_Dern:
    LDA     DernOp
    BNE     AE_Const
    CLR     Saisie
    RTS
AE_Const:                           ; = répété : la dernière opération
    LDX     #Xv
    LDY     #OpA
    JSR     Copie
    LDX     #DernB
    LDY     #OpB
    JSR     Copie
    LDA     DernOp
    JSR     Opere
AE_Fin:
    LBCS    Erreur
    LDX     #Res
    LDY     #Acc
    JSR     Copie
    LDX     #Res
    LDY     #Xv
    JSR     Copie
    CLR     Saisie
    RTS

; --- % : acc x n / 100 si + ou - attend, sinon n / 100 ---
Ac_Pc:
    LDA     Op
    CMPA    #'+'
    BEQ     Pc_Acc
    CMPA    #'-'
    BEQ     Pc_Acc
    LDX     #Xv
    LDY     #OpA
    JSR     Copie
    LDX     #Un
    LDY     #OpB
    JSR     Copie
    BRA     Pc_Mul
Pc_Acc:
    LDX     #Acc
    LDY     #OpA
    JSR     Copie
    LDX     #Xv
    LDY     #OpB
    JSR     Copie
Pc_Mul:
    LDA     #2
    STA     Decal
    JSR     Multiplie
    LBCS    Erreur
Ac_ResX:
    LDX     #Res
    LDY     #Xv
    JSR     Copie
    CLR     Saisie
    RTS

Ac_Rac:
    LDX     #Xv
    LDY     #OpA
    JSR     Copie
    JSR     Racine
    LBCS    Erreur
    BRA     Ac_ResX

; --- la mémoire ---
Ac_MC:
    LDX     #Mem
    JMP     Zero

Ac_MR:
    LDX     #Mem
    LDY     #Xv
    JSR     Copie
    CLR     Saisie
    RTS

Ac_MPlus:
    LDA     #'+'
    BRA     Ac_Mem
Ac_MMoins:
    LDA     #'-'
Ac_Mem:
    PSHS    A
    LDX     #Mem
    LDY     #OpA
    JSR     Copie
    LDX     #Xv
    LDY     #OpB
    JSR     Copie
    PULS    A
    JSR     Opere
    LBCS    Erreur
    LDX     #Res
    LDY     #Mem
    JSR     Copie
    CLR     Saisie
    RTS

; ===================================================================
; L'ARITHMÉTIQUE
; ===================================================================
; Opere : Res = OpA (A = '+' '-' '*' '/') OpB ; C = 1 : Erreur
Opere:
    CMPA    #'+'
    LBEQ    Addition
    CMPA    #'-'
    BNE     Op_M
    LDX     #OpB
    JSR     Negue
    JMP     Addition
Op_M:
    CMPA    #'*'
    BNE     Op_D
    CLR     Decal
    JMP     Multiplie
Op_D:
    JMP     Divise

; Arrondir : T, TSigne -> Res (12 chiffres significatifs au plus, pas
; plus bas que 10^-11) ; C = 1 : 10^12 ou plus
Arrondir:
    LDX     #T
    CLRB
Ar_Cherche:                         ; B = le premier chiffre non nul
    TST     ,X+
    BNE     Ar_Trouve
    INCB
    CMPB    #36
    BLO     Ar_Cherche
    LDX     #Res                    ; moins de 10^-12 : zéro
    JSR     Zero
    ANDCC   #$FE
    RTS
Ar_Trouve:
    CMPB    #11                     ; 10^12 ou plus
    BLS     Ar_Err
    ADDB    #11                     ; le dernier gardé : 11 plus bas, et
    CMPB    #34                     ; pas plus bas que 10^-11
    BLS     Ar_Der
    LDB     #34
Ar_Der:
    STB     Dern
    LDX     #T
    ABX
    LDA     1,X                     ; le chiffre suivant : 5 ou plus, on monte
    CMPA    #5
    BLO     Ar_Coupe
Ar_Plus:
    INC     ,X
    LDA     ,X
    CMPA    #10
    BLO     Ar_Coupe
    CLR     ,X
    LEAX    -1,X
    BRA     Ar_Plus
Ar_Coupe:
    TST     T+11                    ; la retenue a pu atteindre 10^12
    BNE     Ar_Err
    LDB     Dern
    INCB
    LDX     #T
    ABX
Ar_Efface:
    CMPB    #35
    BHS     Ar_Copie
    CLR     ,X+
    INCB
    BRA     Ar_Efface
Ar_Copie:
    LDX     #T+11
    LDY     #Res+1
    LDW     #ND
    TFM     X+,Y+
    LDA     TSigne
    STA     Res
    LDX     #Res                    ; arrondi à zéro (-0,000000000001 x 0,1) :
    JSR     EstNul                  ; zéro reste +
    BNE     Ar_Ok
    CLR     Res
Ar_Ok:
    ANDCC   #$FE
    RTS
Ar_Err:
    ORCC    #1
    RTS

; Addition : Res = OpA + OpB
Addition:
    JSR     T_Clr
    LDA     OpA
    CMPA    OpB
    BNE     Ad_Signes
    STA     TSigne                  ; même signe : |a| + |b|
    LDX     #OpA+1
    LDY     #T+11
    LDW     #ND
    TFM     X+,Y+
    LDX     #T+11
    LDY     #OpB+1
    LDB     #ND
    JSR     AddN
    STA     T+10
    JMP     Arrondir
Ad_Signes:                          ; signes contraires : le plus grand - l'autre
    LDX     #OpA+1
    LDY     #OpB+1
    LDB     #ND
    JSR     CmpN
    BHS     Ad_AB
    LDA     OpB
    STA     TSigne
    LDX     #OpB
    LDY     #OpA
    BRA     Ad_Sous
Ad_AB:
    LDA     OpA
    STA     TSigne
    LDX     #OpA
    LDY     #OpB
Ad_Sous:
    PSHS    Y
    LEAX    1,X
    LDY     #T+11
    LDW     #ND
    TFM     X+,Y+
    PULS    Y
    LEAY    1,Y
    LDX     #T+11
    LDB     #ND
    JSR     SubN
    JMP     Arrondir

; Multiplie : Res = OpA x OpB x 10^-Decal (Decal = 0, ou 2 pour %)
; Chiffres p de a et q de b : le produit vaut 10^(24-p-q) = T[p+q-1].
Multiplie:
    JSR     T_Clr
    LDA     OpA
    EORA    OpB
    STA     TSigne
    LDA     #1
    STA     Mp
Mu_P:
    LDX     #OpA+1
    LDB     Mp
    LDA     B,X
    BEQ     Mu_PSuiv
    STA     ChA
    LDA     #1
    STA     Mq
Mu_Q:
    LDX     #OpB+1
    LDB     Mq
    LDB     B,X
    BEQ     Mu_QSuiv
    LDA     ChA
    MUL
    PSHS    B
    LDA     Mp
    ADDA    Mq
    DECA
    ADDA    Decal
    LDX     #T
    LEAX    A,X
    PULS    A
    JSR     AjouteT
Mu_QSuiv:
    INC     Mq
    LDA     Mq
    CMPA    #ND
    BLO     Mu_Q
Mu_PSuiv:
    INC     Mp
    LDA     Mp
    CMPA    #ND
    BLO     Mu_P
    JMP     Arrondir

; Divise : Res = OpA / OpB ; C = 1 si OpB = 0. Division longue des 24
; chiffres de a suivis de 12 zéros par b : le quotient j va en T[j].
Divise:
    LDX     #OpB
    JSR     EstNul
    BNE     Dv_Ok
    ORCC    #1
    RTS
Dv_Ok:
    JSR     T_Clr
    LDA     OpA
    EORA    OpB
    STA     TSigne
    LDX     #Reste
    JSR     Zero
    CLR     Divi
    LDX     #OpB+1
    LDY     #Divi+1
    LDW     #ND
    TFM     X+,Y+
    CLR     Dj
Dv_J:
    LDX     #Reste+1                ; reste x 10 + le chiffre suivant
    LDY     #Reste
    LDW     #ND
    TFM     X+,Y+
    CLRA
    LDB     Dj
    CMPB    #ND
    BHS     Dv_Ch
    LDX     #OpA+1
    LDA     B,X
Dv_Ch:
    STA     Reste+ND
    CLR     Qd
Dv_Sous:
    LDX     #Reste
    LDY     #Divi
    LDB     #NB
    JSR     CmpN
    BLO     Dv_Pose
    LDX     #Reste
    LDY     #Divi
    LDB     #NB
    JSR     SubN
    INC     Qd
    BRA     Dv_Sous
Dv_Pose:
    LDX     #T
    LDB     Dj
    ABX
    LDA     Qd
    STA     ,X
    INC     Dj
    LDA     Dj
    CMPA    #36
    BLO     Dv_J
    JMP     Arrondir

; Racine : Res = racine de OpA ; C = 1 si OpA < 0. X = a x 10^11 (24
; chiffres), suivi de 13 zéros et précédé d'un : 19 paires ; le chiffre k
; de la racine vaut 10^(6-k) : T[17+k].
Racine:
    LDX     #OpA
    JSR     EstNul
    BNE     Ra_Non0
    LDX     #Res
    JSR     Zero
    ANDCC   #$FE
    RTS
Ra_Non0:
    TST     OpA
    BEQ     Ra_Ok
    ORCC    #1
    RTS
Ra_Ok:
    JSR     T_Clr
    CLR     TSigne
    LDX     #Rr
    LDB     #RL
    JSR     ZeroN
    LDX     #Pp
    LDB     #RL
    JSR     ZeroN
    CLR     Rk
Ra_K:
    LDX     #Rr+2                   ; reste x 100 + la paire
    LDY     #Rr
    LDW     #RL-2
    TFM     X+,Y+
    LDB     Rk
    ASLB
    JSR     Chiffre38
    STA     Rr+RL-2
    LDB     Rk
    ASLB
    INCB
    JSR     Chiffre38
    STA     Rr+RL-1
    LDX     #Pp+1                   ; Tt = 20 P + 1
    LDY     #Tt
    LDW     #RL-1
    TFM     X+,Y+
    CLR     Tt+RL-1
    LDX     #Tt
    LDB     #RL
    JSR     Double
    LDA     #1
    STA     Tt+RL-1
    CLR     Qd
Ra_Sous:
    LDX     #Rr
    LDY     #Tt
    LDB     #RL
    JSR     CmpN
    BLO     Ra_Pose
    LDX     #Rr
    LDY     #Tt
    LDB     #RL
    JSR     SubN
    LDX     #Tt+RL-1                ; l'impair suivant
    LDA     #2
    JSR     AjouteT
    INC     Qd
    BRA     Ra_Sous
Ra_Pose:
    LDX     #Pp+1                   ; P = 10 P + d
    LDY     #Pp
    LDW     #RL-1
    TFM     X+,Y+
    LDA     Qd
    STA     Pp+RL-1
    LDX     #T+17
    LDB     Rk
    ABX
    STA     ,X
    INC     Rk
    LDA     Rk
    CMPA    #19
    LBLO    Ra_K
    JMP     Arrondir

; Chiffre38 : B = 0-37 -> A = le chiffre B de 0, a (24 chiffres), 13 zéros
Chiffre38:
    CLRA
    TSTB
    BEQ     C38_Fin
    CMPB    #ND
    BHI     C38_Fin
    LDX     #OpA
    LDA     B,X
C38_Fin:
    RTS

; --- outils sur les chiffres (X, Y : premiers chiffres ; B : combien) ---
; AddN : X += Y -> A = la retenue sortante. Détruit B, E, X, Y.
AddN:
    ABX
    LEAY    B,Y
    TFR     B,E
    CLRB
AN_B:
    LDA     ,-X
    ADDA    ,-Y
    PSHS    B
    ADDA    ,S+
    CLRB
    CMPA    #10
    BLO     AN_P
    SUBA    #10
    INCB
AN_P:
    STA     ,X
    DECE
    BNE     AN_B
    TFR     B,A
    RTS

; SubN : X -= Y (X >= Y). Détruit A, B, E, X, Y.
SubN:
    ABX
    LEAY    B,Y
    TFR     B,E
    CLRB
SN_B:
    LDA     ,-X
    SUBA    ,-Y
    PSHS    B
    SUBA    ,S+
    BPL     SN_P
    ADDA    #10
    LDB     #1
    BRA     SN_S
SN_P:
    CLRB
SN_S:
    STA     ,X
    DECE
    BNE     SN_B
    RTS

; CmpN : compare X et Y -> drapeaux du premier CMPA différent (Z = 1 :
; égaux ; C = 1 : X < Y). Détruit A, B, X, Y.
CmpN:
    LDA     ,X+
    CMPA    ,Y+
    BNE     CN_F
    DECB
    BNE     CmpN
CN_F:
    RTS

; Double : X = 2 X. Détruit A, B, E, X.
Double:
    ABX
    TFR     B,E
    CLRB
DB_B:
    LDA     ,-X
    ASLA
    PSHS    B
    ADDA    ,S+
    CLRB
    CMPA    #10
    BLO     DB_P
    SUBA    #10
    INCB
DB_P:
    STA     ,X
    DECE
    BNE     DB_B
    RTS

; AjouteT : X = un chiffre, A = ce qu'on y ajoute (retenues vers la
; gauche). Détruit A, B, X.
AjouteT:
    ADDA    ,X
    CLRB
AT_Dix:
    CMPA    #10
    BLO     AT_Pose
    SUBA    #10
    INCB
    BRA     AT_Dix
AT_Pose:
    STA     ,X
    TSTB
    BEQ     AT_Fin
    TFR     B,A
    LEAX    -1,X
    BRA     AjouteT
AT_Fin:
    RTS

T_Clr:
    LDX     #T
    LDB     #TL
    BRA     ZeroN
; Zero : X = un nombre -> 0 (NB octets) ; ZeroN : B octets. Détruit B, X.
Zero:
    LDB     #NB
ZeroN:
    CLR     ,X+
    DECB
    BNE     ZeroN
    RTS

; Copie : X -> Y, un nombre. Détruit W, X, Y.
Copie:
    LDW     #NB
    TFM     X+,Y+
    RTS

; EstNul : X = un nombre -> Z = 1 s'il est nul. Détruit B, X.
EstNul:
    LEAX    1,X
    LDB     #ND
EN_B:
    TST     ,X+
    BNE     EN_F
    DECB
    BNE     EN_B
EN_F:
    RTS

; Negue : X = un nombre -> son opposé (zéro reste +). Détruit B.
Negue:
    PSHS    X
    BSR     EstNul
    PULS    X
    BEQ     Ng_Fin
    LDA     ,X
    EORA    #1
    STA     ,X
Ng_Fin:
    RTS

; ===================================================================
; L'ÉCRAN : chaque rangée composée dans VisTxt (lib/vision.asm, cases
; caractère:attribut, CP437 sans traduction), puis copiée par vis_Ligne
; dans la trame.
; ===================================================================
Dessine_Tout:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #WIN_X
    LDB     #WIN_Y
    LDW     #(WIN_W*256)+WIN_H
    LDY     #TxtTitre
    JSR     [VIS_TABLE+vis_Window]
    JSR     [VIS_TABLE+vis_Sync_End]
    JSR     Compose_LCD
    LDB     #R_LCD
    JSR     Ecrit_Rangee
    CLR     LigD
DT_L:
    LDB     LigD
    JSR     Compose_Touches
    LDB     LigD
    ASLB
    ADDB    #R_TOUCHES
    JSR     Ecrit_Rangee
    INC     LigD
    LDA     LigD
    CMPA    #5
    BLO     DT_L
    LDX     #Aide1
    JSR     Compose_Aide
    LDB     #R_AIDE
    JSR     Ecrit_Rangee
    LDX     #Aide2
    JSR     Compose_Aide
    LDB     #R_AIDE+1
    JMP     Ecrit_Rangee

; Redessine : l'écran LCD, et les rangées de l'ancienne et de la nouvelle
; touche sélectionnée si elle a changé
Redessine:
    JSR     Compose_LCD
    LDB     #R_LCD
    JSR     Ecrit_Rangee
    LDA     Sel
    CMPA    AncSel
    BEQ     Rd_Fin
    LDA     AncSel
    BSR     Rang_De
    LDA     Sel
    BRA     Rang_De
Rd_Fin:
    RTS

; Rang_De : A = une touche -> sa rangée redessinée
Rang_De:
    CLRB
RD_B:
    CMPA    #5
    BLO     RD_F
    SUBA    #5
    INCB
    BRA     RD_B
RD_F:
    PSHS    B
    JSR     Compose_Touches
    PULS    B
    ASLB
    ADDB    #R_TOUCHES
    ; (Ecrit_Rangee suit)

; Ecrit_Rangee : VisTxt (composé) -> la rangée B de la fenêtre
Ecrit_Rangee:
    PSHS    B
    JSR     [VIS_TABLE+vis_Sync_Begin]
    PULS    B
    ADDB    #WIN_Y
    LDA     #WIN_X+1
    JSR     [VIS_TABLE+vis_Ligne]
    JMP     [VIS_TABLE+vis_Sync_End]

Fond2:
    LDD     #(UI_SPACE*256)+COLOR_WIN
    STD     ,Y++
    STD     ,Y++
    RTS

; Compose_LCD : 2 cases de fond, l'écran (24 cases : M, l'opération, le
; nombre calé à droite sur 22), 2 cases de fond
Compose_LCD:
    JSR     Texte_Aff
    LDY     #VisTxt
    BSR     Fond2
    LDX     #Mem
    JSR     EstNul
    BEQ     CL_Vide
    LDA     #'M'
    BRA     CL_M
CL_Vide:
    LDA     #' '
CL_M:
    LDB     #A_LCD
    STD     ,Y++
    LDA     Op
    BEQ     CL_Esp
    CMPA    #'*'
    BNE     CL_O1
    LDA     #'x'
    BRA     CL_O
CL_O1:
    CMPA    #'/'
    BNE     CL_O
    LDA     #C_DIV
    BRA     CL_O
CL_Esp:
    LDA     #' '
CL_O:
    LDB     #A_LCD
    STD     ,Y++
    LDA     #22
    SUBA    AffN
    STA     Cpt
CL_Blanc:
    TST     Cpt
    BEQ     CL_Nb
    LDD     #(32*256)+A_LCD
    STD     ,Y++
    DEC     Cpt
    BRA     CL_Blanc
CL_Nb:
    LDX     #Aff
    LDE     AffN
CL_N:
    LDA     ,X+
    LDB     #A_LCD
    STD     ,Y++
    DECE
    BNE     CL_N
    BSR     Fond2
    LDA     #LARGE
    STA     VisLong
    RTS

; Compose_Touches : B = rangée du clavier (0-4)
Compose_Touches:
    STB     Lig
    LDY     #VisTxt
    BSR     Fond2
    LDA     Lig
    LDB     #5
    MUL
    STB     Kc
    LDA     #5
    STA     Cpt
CT_K:
    LDB     Kc
    CMPB    Sel
    BNE     CT_G
    LDB     #A_SEL
    BRA     CT_A
CT_G:
    LDX     #Genre
    LDB     B,X
CT_A:
    STB     AttK
    LDB     Kc
    LDA     #4
    MUL
    LDX     #Etiq
    LEAX    D,X
    LDE     #4
CT_C:
    LDA     ,X+
    LDB     AttK
    STD     ,Y++
    DECE
    BNE     CT_C
    INC     Kc
    DEC     Cpt
    BEQ     CT_Fin
    LDD     #(UI_SPACE*256)+COLOR_WIN
    STD     ,Y++
    BRA     CT_K
CT_Fin:
    LBSR    Fond2
    LDA     #LARGE
    STA     VisLong
    RTS

; Compose_Aide : X = une ligne d'aide (0 final) -> une case de fond, la
; ligne, du fond jusqu'à LARGE
Compose_Aide:
    LDY     #VisTxt
    LDD     #(UI_SPACE*256)+COLOR_WIN
    STD     ,Y++
    LDE     #1
CA_C:
    LDA     ,X+
    BEQ     CA_Fond
    LDB     #A_AIDE
    STD     ,Y++
    INCE
    BRA     CA_C
CA_Fond:
    CMPE    #LARGE
    BHS     CA_Fin
    LDD     #(UI_SPACE*256)+COLOR_WIN
    STD     ,Y++
    INCE
    BRA     CA_Fond
CA_Fin:
    LDA     #LARGE
    STA     VisLong
    RTS

; Texte_Aff : Aff, AffN = ce que montre l'écran (Erreur, la saisie, ou Xv)
Texte_Aff:
    LDY     #Aff
    TST     Err
    BEQ     TA_1
    LDX     #TxtErreur
TA_Err:
    LDA     ,X+
    BEQ     TA_Fin
    STA     ,Y+
    BRA     TA_Err
TA_1:
    TST     Saisie
    BEQ     TA_Nb
    TST     ENeg
    BEQ     TA_S1
    LDA     #'-'
    STA     ,Y+
TA_S1:
    LDB     EEntN
    BNE     TA_Ent
    LDA     #'0'
    STA     ,Y+
    BRA     TA_Pt
TA_Ent:
    LDX     #EEnt
TA_E:
    LDA     ,X+
    ADDA    #'0'
    STA     ,Y+
    DECB
    BNE     TA_E
TA_Pt:
    TST     EPt
    BEQ     TA_Fin
    LDA     #'.'
    STA     ,Y+
    LDB     EDecN
    BEQ     TA_Fin
    LDX     #EDec
TA_D:
    LDA     ,X+
    ADDA    #'0'
    STA     ,Y+
    DECB
    BNE     TA_D
TA_Fin:
    TFR     Y,D
    SUBD    #Aff
    STB     AffN
    RTS
TA_Nb:
    TST     Xv
    BEQ     TN_1
    LDA     #'-'
    STA     ,Y+
TN_1:
    LDX     #Xv+2                   ; la partie entière : 10^11 .. 10^0
    LDB     #12
TN_Z:
    LDA     ,X
    BNE     TN_Ent
    LEAX    1,X
    DECB
    BNE     TN_Z
    LDA     #'0'
    STA     ,Y+
    BRA     TN_Dec
TN_Ent:
    LDA     ,X+
    ADDA    #'0'
    STA     ,Y+
    DECB
    BNE     TN_Ent
TN_Dec:                             ; les décimales, sans les zéros de fin
    LDX     #Xv+NB
    LDB     #11
TN_Der:
    LDA     ,-X
    BNE     TN_Frac
    DECB
    BNE     TN_Der
    BRA     TA_Fin
TN_Frac:
    LDA     #'.'
    STA     ,Y+
    LDX     #Xv+14
TN_F:
    LDA     ,X+
    ADDA    #'0'
    STA     ,Y+
    DECB
    BNE     TN_F
    BRA     TA_Fin

    include "../lib/vision.asm"
    include "../lib/joy.asm"

; ===================================================================
; DONNÉES
; ===================================================================
; le clavier du PC -> l'indice de la touche (0 final)
TabCles     FCB '0',20,'1',15,'2',16,'3',17,'4',10,'5',11,'6',12,'7',5,'8',6,'9',7
            FCB '.',21,',',21,'+',23,'-',18,'*',13,'x',13,'X',13,'/',8,'=',24,$0D,24
            FCB 'c',4,'C',4,$88,4,$08,9,'v',14,'V',14,'n',22,'N',22,'%',19
            FCB 'p',3,'P',3,'m',2,'M',2,'r',1,'R',1,'e',0,'E',0
            FCB 0
TabActions  FDB Ac_MC,Ac_MR,Ac_MMoins,Ac_MPlus,Remise
            FDB Ac_Chiffre,Ac_Chiffre,Ac_Chiffre,Ac_Oper,Ac_Ret
            FDB Ac_Chiffre,Ac_Chiffre,Ac_Chiffre,Ac_Oper,Ac_Rac
            FDB Ac_Chiffre,Ac_Chiffre,Ac_Chiffre,Ac_Oper,Ac_Pc
            FDB Ac_Chiffre,Ac_Point,Ac_PM,Ac_Oper,Ac_Egal
ValCh       FCB 0,0,0,0,0,7,8,9,0,0,4,5,6,0,0,1,2,3,0,0,0,0,0,0,0
OpCode      FCB 0,0,0,0,0,0,0,0,'/',0,0,0,0,'*',0,0,0,0,'-',0,0,0,0,'+',0
Genre       FCB A_FONC,A_FONC,A_FONC,A_FONC,A_FONC
            FCB A_CHIFFRE,A_CHIFFRE,A_CHIFFRE,A_OPER,A_FONC
            FCB A_CHIFFRE,A_CHIFFRE,A_CHIFFRE,A_OPER,A_FONC
            FCB A_CHIFFRE,A_CHIFFRE,A_CHIFFRE,A_OPER,A_FONC
            FCB A_CHIFFRE,A_CHIFFRE,A_CHIFFRE,A_OPER,A_OPER
Etiq        FCC " MC  MR  M-  M+   C "
            FCC "  7   8   9 "
            FCB 32,32,C_DIV,32
            FCC " <- "
            FCC "  4   5   6   x  Rac"
            FCC "  1   2   3   -   % "
            FCC "  0   . "
            FCB 32,32,C_PM,32
            FCC "  +   = "
Aide1       FCC "v=racine n="
            FCB C_PM
            FCN " c=C Echap=fin"
Aide2       FCN "p=M+ m=M- r=MR e=MC"
TxtTitre    FCN " Calculatrice "
TxtErreur   FCN "Erreur"
Un          FCB 0
            FCB 0,0,0,0,0,0,0,0,0,0,0,0
            FCB 1
            FCB 0,0,0,0,0,0,0,0,0,0,0

; --- les variables ---
Acc         RMB NB              ; l'accumulateur (avant l'opération en attente)
Xv          RMB NB              ; le nombre affiché
Mem         RMB NB              ; la mémoire
DernB       RMB NB              ; = répété : le nombre de la dernière opération
OpA         RMB NB              ; les opérandes et le résultat de l'arithmétique
OpB         RMB NB
Res         RMB NB
Reste       RMB NB              ; Divise
Divi        RMB NB
Rr          RMB RL              ; Racine
Pp          RMB RL
Tt          RMB RL
T           RMB TL
TSigne      RMB 1
Dern        RMB 1
Decal       RMB 1
Mp          RMB 1
Mq          RMB 1
ChA         RMB 1
Dj          RMB 1
Qd          RMB 1
Rk          RMB 1
Op          RMB 1               ; '+' '-' '*' '/' en attente, ou 0
DernOp      RMB 1
NouvOp      RMB 1
Err         RMB 1
Saisie      RMB 1               ; 1 : un nombre est en train d'être tapé
EEnt        RMB 12              ; ses chiffres (0-9) : partie entière
EEntN       RMB 1
EDec        RMB 11              ; décimales
EDecN       RMB 1
EPt         RMB 1
ENeg        RMB 1
Tch         RMB 1
Sel         RMB 1               ; la touche sélectionnée
AncSel      RMB 1
Evts        RMB 1
LigS        RMB 1
ColS        RMB 1
Lig         RMB 1
LigD        RMB 1
Kc          RMB 1
AttK        RMB 1
Cpt         RMB 1
Aff         RMB 24              ; le texte de l'écran
AffN        RMB 1
