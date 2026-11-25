; ===================================================================
; essai_cycles.asm - Combien de cycles prend une opération ? (par TELE)
; ===================================================================
; Module d'essai pour TELE (page 1, $1000). Appel : A = mesure.
; Le budget de la mémoire vidéo est la fenêtre après le signal de trame
; (34 lignes sur la mono, banc NEIGE) : il faut des CYCLES réels.
;
; Principe (comme NEIGE) : IRQ masquées, on guette le drapeau de trame du
; 68B40 et on compte les tours d'une boucle fixe pendant une trame entière
; (Tours ; une trame VGA = 525 lignes = 30 751 cycles de E). Puis, juste
; après un signal, on exécute l'opération et on compte les tours restants
; jusqu'au signal suivant (Reste). Cycles(op) = (Reste(0) - Reste(op)) x
; 30 751 / Tours. Les opérations travaillent en RAM de la page 1 (rien à
; l'écran) : un accès à la VRAM coûte les mêmes cycles.
;   A = 0 : rien (référence)       A = 3 : deux rangées par TFM
;   A = 1 : une rangée par TFM     A = 4 : une rangée effacée par TFM
;   A = 2 : une rangée effacée case par case (la boucle de Zone_IRQ)
;   Sortie : D = Reste, X = Tours.
;   A = 5 : IRQ ACTIVES. Envoie 30 sauts de ligne à la console (le
;   Terminal défile), puis compte les tours de 40 trames de suite avec une
;   boucle de même durée (le compteur vsync_tick au lieu du drapeau) :
;   Prof ($1F00, 40 mots). IRQ(trame) = (Tours - Prof[k]) x 30 751 / Tours.
;   Sortie : X = Tours.
; Rangée du Terminal sur la mono : 76 cases x 2 octets = 152.
; ===================================================================
    include "../../bios/hardware.inc"
    include "../../bios/sysfunc.inc"

LARG            equ 76              ; cases d'une rangée du Terminal
OCTETS          equ LARG*2          ; mono : caractère et couleur se suivent
BUF1            equ $3000
BUF2            equ $3200
PROF            equ $1F00
N_PROF          equ 40

    org     $1000

Entree:
    PSHS    CC
    ORCC    #%01010000          ; IRQ et FIRQ masquées
    STA     Op
    LBSR    Mesure              ; Tours
    LDA     Op
    CMPA    #5
    BEQ     Profil
    LBSR    Signal
    LDA     Op
    LSLA
    LDX     #Table
    JSR     [A,X]
    LDX     #0
Re_Tour:                        ; mêmes instructions que Me_Tour
    LEAX    1,X
    LDA     STATUS
    BITA    #1
    BEQ     Re_Tour
    STX     Reste
    LDX     TIMER1              ; drapeau effacé
    LDD     Reste
    LDX     Tours
    PULS    CC,PC

; --- A = 5 : le coût de l'IRQ du BIOS, trame par trame -------------
Profil:
    LDA     STATUS              ; drapeau effacé avant d'ouvrir les IRQ
    LDX     TIMER1
    ANDCC   #%10101111
    LDB     #30
Pr_LF:
    LDA     #$0A
    PSHS    B
    JSR     [table_function_ram+sys_PrintChar]
    PULS    B
    DECB
    BNE     Pr_LF
    LDA     vsync_tick+1        ; se caler sur un début de trame
Pr_Cale:
    CMPA    vsync_tick+1
    BEQ     Pr_Cale
    LDA     vsync_tick+1
    LDY     #PROF
    LDB     #N_PROF
Pr_Trame:
    STA     Pr_Cmp+1            ; l'immédiat de CMPA : la valeur actuelle
    LDX     #0
Pr_Tour:                        ; même durée que Me_Tour (LDA étendu, imm., BEQ)
    LEAX    1,X
    LDA     vsync_tick+1
Pr_Cmp:
    CMPA    #0
    BEQ     Pr_Tour
    STX     ,Y++
    DECB
    BNE     Pr_Trame
    LDX     Tours
    CLRA
    CLRB
    PULS    CC,PC

; Signal : attend le drapeau du timer 1 et l'efface. Détruit A, X.
Signal:
    LDA     STATUS
    BITA    #1
    BEQ     Signal
    LDX     TIMER1
    RTS

; Mesure : Tours = tours de boucle pendant une trame (la dernière de 4).
Mesure:
    LDB     #4
Me_Trame:
    PSHS    B
    BSR     Signal
    LDX     #0
Me_Tour:
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

; --- les opérations mesurées --------------------------------------
Op_Rien:
    RTS

Op_Rangee:                      ; Zone_IRQ mono : une rangée = un bloc
    LDX     #BUF1
    LDU     #BUF2
    LDW     #OCTETS
    TFM     U+,X+
    RTS

Op_Efface:                      ; Zi_EffCase, tel quel
    LDX     #BUF1
    LDA     #$20
    LDB     #$1F
    LDF     #LARG
Oe_Case:
    STD     ,X++
    DECF
    BNE     Oe_Case
    RTS

Op_Deux:                        ; défilement : deux rangées par trame
    LDX     #BUF1
    LDU     #BUF2
    LDW     #OCTETS
    TFM     U+,X+
    LDX     #BUF1
    LDU     #BUF2
    LDW     #OCTETS
    TFM     U+,X+
    RTS

Op_EffTfm:                      ; effacement par TFM : la première case
    LDX     #BUF1               ; recopiée de proche en proche
    LDD     #$201F
    STD     ,X
    LEAU    ,X
    LEAX    2,X
    LDW     #OCTETS-2
    TFM     U+,X+
    RTS

Table:
    FDB     Op_Rien,Op_Rangee,Op_Efface,Op_Deux,Op_EffTfm

Op      FCB 0
Tours   FDB 0
Reste   FDB 0
