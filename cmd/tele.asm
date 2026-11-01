; ===================================================================
; TELE.ASM — Télécommande de la machine par la liaison série
; Usage: TELE     (Echap au clavier : retour)
; Charge: page 1, $0000
;
; Pour la mise au point depuis le PC (tools/tele/tele.py) : lire et
; écrire la mémoire, appeler une routine, sans écran ni clavier. Le code
; d'essai se charge plus loin dans la page 1 (TELE s'arrête bien avant
; $1000) et s'appelle par JSR, tous registres chargés ; les services du
; BIOS s'appellent de même (adresse lue dans table_function_ram).
;
; Liaison : 115200 bauds 8N1 (réglage du BIOS), réception en mode brut
; (anneau serie_buf rempli par la NMI), émission par scrutation de SR.
; Trame du PC :   'T' cmd n données(n) somme
;                 somme = cmd + n + données, modulo 256
; Réponse :       'K' résultat somme(résultat)   ou   'E' code
;                 (1 : somme fausse, 2 : commande inconnue, 3 : longueur)
;   'P'                          -> "TELE1"
;   'R' page adrH adrL n         -> les n octets (n = 1..255)
;   'W' page adrH adrL octets... -> rien
;   'C' adrH adrL A B X Y U      -> CC A B E F X Y U au retour (11 octets),
;                                   après JSR adr (page 1 ou >= $8000)
;   'Q'                          -> rien ; TELE rend la main
; page : 0-3 pour $0000-$7FFF (accès direct pour la page 1, la nôtre,
; sys_FarRead / sys_FarWrite sinon) ; ignorée à partir de $8000 (accès
; direct : on peut lire et écrire les registres d'entrée-sortie).
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

    section .code

Start:
    STS     PileDepart
    LDX     #MsgTitre
    JSR     [table_function_ram+sys_PrintString]
    JSR     [table_function_ram+sys_PrintCRLF]
    LDA     serie_tete          ; anneau vide, puis mode brut
    STA     serie_queue
    LDA     #1
    STA     serie_brute

; --- Une trame : 'T' cmd n données somme ---
Boucle:
    JSR     Rx
    CMPA    #'T'
    BNE     Boucle
    JSR     Rx
    STA     Cmd
    STA     Somme
    JSR     Rx
    STA     Long
    STA     Reste
    ADDA    Somme
    STA     Somme
    LDX     #Tampon
    STX     Ptr
TR_Oct:
    TST     Reste
    BEQ     TR_Somme
    JSR     Rx
    LDX     Ptr
    STA     ,X+
    STX     Ptr
    ADDA    Somme
    STA     Somme
    DEC     Reste
    BRA     TR_Oct
TR_Somme:
    JSR     Rx
    CMPA    Somme
    BEQ     Dispatch
    LDA     #1
    BRA     Erreur

Dispatch:
    LDA     Cmd
    CMPA    #'P'
    BEQ     Cmd_P
    CMPA    #'R'
    BEQ     Cmd_R
    CMPA    #'W'
    LBEQ    Cmd_W
    CMPA    #'C'
    LBEQ    Cmd_C
    CMPA    #'Q'
    LBEQ    Cmd_Q
    LDA     #2
Erreur:
    PSHS    A
    LDA     #'E'
    JSR     Tx
    PULS    A
    JSR     Tx
    BRA     Boucle

Mauvaise_Long:
    LDA     #3
    BRA     Erreur

; --- 'P' : présence ---
Cmd_P:
    JSR     Rep_K
    LDX     #MsgVersion
CP_Oct:
    LDA     ,X+
    BEQ     CP_Fin
    JSR     Rep_Octet
    BRA     CP_Oct
CP_Fin:
    JSR     Rep_Fin
    LBRA    Boucle

; --- 'R' page adr n : lire ---
Cmd_R:
    LDA     Long
    CMPA    #4
    BNE     Mauvaise_Long
    LDB     Tampon+3
    BEQ     Mauvaise_Long
    JSR     Direct              ; Z = 1 : accès direct
    BNE     CR_Loin
    LDX     Tampon+1
    LDY     #Donnees
    LDB     Tampon+3
CR_Copie:
    LDA     ,X+
    STA     ,Y+
    DECB
    BNE     CR_Copie
    BRA     CR_Envoie
CR_Loin:
    LDB     Tampon+3
    CLRA
    TFR     D,U                 ; U = n
    LDA     Tampon              ; page source
    LDB     current_page        ; page destination : la nôtre
    LDX     Tampon+1
    LDY     #Donnees
    JSR     [table_function_ram+sys_FarRead]
CR_Envoie:
    JSR     Rep_K
    LDX     #Donnees
    LDB     Tampon+3
CR_Tx:
    LDA     ,X+
    JSR     Rep_Octet
    DECB
    BNE     CR_Tx
    JSR     Rep_Fin
    LBRA    Boucle

; --- 'W' page adr octets... : écrire ---
Cmd_W:
    LDB     Long
    SUBB    #3
    BLS     Mauvaise_Long       ; au moins un octet
    STB     Reste
    JSR     Direct
    BNE     CW_Loin
    LDX     #Tampon+3
    LDY     Tampon+1
CW_Copie:
    LDA     ,X+
    STA     ,Y+
    DECB
    BNE     CW_Copie
    BRA     CW_Fin
CW_Loin:
    LDB     Reste
    CLRA
    TFR     D,U                 ; U = n
    LDA     Tampon              ; page destination
    LDB     current_page        ; page source : la nôtre
    LDX     #Tampon+3
    LDY     Tampon+1
    JSR     [table_function_ram+sys_FarWrite]
CW_Fin:
    JSR     Rep_K
    JSR     Rep_Fin
    LBRA    Boucle

; --- 'C' adr A B X Y U : appel ---
Cmd_C:
    LDA     Long
    CMPA    #10
    LBNE    Mauvaise_Long
    LDD     Tampon
    STD     Cible
    LDA     Tampon+2
    LDB     Tampon+3
    LDX     Tampon+4
    LDY     Tampon+6
    LDU     Tampon+8
    JSR     [Cible]
    PSHS    CC
    STA     Regs+1
    STB     Regs+2
    STW     Regs+3
    STX     Regs+5
    STY     Regs+7
    STU     Regs+9
    PULS    A
    STA     Regs
    JSR     Rep_K
    LDX     #Regs
    LDB     #11
CC_Tx:
    LDA     ,X+
    JSR     Rep_Octet
    DECB
    BNE     CC_Tx
    JSR     Rep_Fin
    LBRA    Boucle

; --- 'Q' : fin ---
Cmd_Q:
    JSR     Rep_K
    JSR     Rep_Fin
Quitter:
    CLR     serie_brute         ; la ligne repasse au BIOS
    LDS     PileDepart
    LDX     #MsgFin
    JSR     [table_function_ram+sys_PrintString]
    JMP     [table_function_ram+sys_PrintCRLF]

; Z = 1 si l'adresse Tampon+1 se lit directement : >= $8000, ou page 1
; (la nôtre).
Direct:
    LDA     Tampon+1
    BMI     DI_Oui
    LDA     Tampon
    CMPA    current_page
    RTS
DI_Oui:
    CLRA                        ; Z = 1
    RTS

; --- Liaison ---
; A = octet reçu (anneau de la NMI). Echap au clavier : on quitte, d'où
; que l'on soit. Détruit B et X.
Rx:
    LDB     serie_queue
    CMPB    serie_tete
    BNE     RX_Lu
    JSR     [table_function_ram+sys_kbd_poll]
    CMPA    #$1B
    BNE     Rx
    BRA     Quitter
RX_Lu:
    LDX     #serie_buf
    ABX                         ; B non signé
    LDA     ,X
    INCB
    STB     serie_queue
    RTS

; A -> ligne série (attend que TDR soit libre). Préserve tout sauf CC.
Tx:
    PSHS    B
TX_Att:
    LDB     SR
    BITB    #$02
    BEQ     TX_Att
    STA     TDR
    PULS    B,PC

Rep_K:
    CLR     SommeTx
    LDA     #'K'
    BRA     Tx

; A -> ligne, compté dans la somme
Rep_Octet:
    PSHS    A
    ADDA    SommeTx
    STA     SommeTx
    PULS    A
    BRA     Tx

Rep_Fin:
    LDA     SommeTx
    BRA     Tx

MsgTitre:       FCN "TELE : telecommande par la liaison serie (Echap : fin)"
MsgFin:         FCN "TELE termine."
MsgVersion:     FCN "TELE1"

; --- Variables ---
PileDepart      rmb 2
Cmd             rmb 1
Long            rmb 1
Reste           rmb 1
Somme           rmb 1
SommeTx         rmb 1
Ptr             rmb 2
Cible           rmb 2
Regs            rmb 11
Tampon          rmb 256
Donnees         rmb 256
