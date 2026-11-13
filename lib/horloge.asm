; ===================================================================
; HORLOGE.ASM - Pilote du MC146818 (horloge sauvegardée) sur le PIA
; ===================================================================
; La petite carte RTC se branche sur le connecteur du PIA (J4 de la V3,
; J102 de la mono). Le bus multiplexé du MC146818 est trop lent pour le
; bus à 1,8432 MHz : il est mené à la main, en mode Motorola.
;   PA0-7 = AD0-7 (sorties au repos, entrées pendant une lecture)
;   CA2   = AS    (sortie : CRA b5 = b4 = 1, niveau = b3)
;   PB0   = DS    PB1 = R/W  (tirages 10 k vers +5 V sur la carte)
;   CA1   = /IRQ  (tirage 10 k ; l'IRQ du PIA reste coupée : elle irait
;                  sur la FIRQ, dont le gestionnaire n'est qu'un RTI)
; Cycle (figure 2 de la fiche) : adresse sur AD, AS monte puis descend
; (DS est bas : la puce se met en mode Motorola et verrouille l'adresse),
; puis DS monte : en lecture (R/W = 1) la puce tient AD tant que DS = 1 ;
; en écriture (R/W = 0) la donnée est prise au front descendant de DS.
; R/W et AS ne changent que DS bas. Chaque accès au PIA dure plus d'une
; µs : toutes les durées minimales de la fiche (325 ns au plus) tiennent.
; Repos : DS = 0, R/W = 1, AS = 0, PA en sorties.
;
; Hor_Init   : met le PIA au repos (à appeler avant le premier accès)
; Hor_Lit    : A = registre -> A = valeur (B, X, Y gardés)
; Hor_Ecrit  : A = registre, B = valeur (A, B, X, Y gardés)
; Hor_Etat   : C = 1 si la puce ne répond pas (registre D : b0-6 = 0 sur
;              un MC146818 ; sans carte, les tirages du port A rendent $FF)
;              sinon A = registre D (b7 VRT = 0 : la pile a lâché)
; Hor_LitDate: X -> 7 octets HOR_SEC..HOR_AN, une lecture cohérente
; Hor_Regle  : X -> 7 octets ; règle l'horloge (BCD, 24 h, base 32 kHz)
; Code : à inclure APRÈS le point d'entrée.
; ===================================================================
HOR_SEC         equ 0               ; ordre des 7 octets d'une date
HOR_MIN         equ 1
HOR_HEURE       equ 2
HOR_JS          equ 3               ; jour de la semaine, 1 = dimanche
HOR_JOUR        equ 4
HOR_MOIS        equ 5
HOR_AN          equ 6               ; 00-99 (20xx)

HOR_REGA        equ 10
HOR_REGB        equ 11
HOR_REGC        equ 12
HOR_REGD        equ 13
HOR_RAM         equ 14              ; 50 octets de RAM sauvegardée (14-63)
HOR_A_32K       equ $20             ; registre A : DV = 010 (32,768 kHz), pas de SQW
HOR_B_SET       equ $82             ; registre B : SET, 24 h, BCD
HOR_B_MARCHE    equ $02             ; registre B : 24 h, BCD, aucune IT

HOR_CRA_DDR     equ $30             ; CA2 sortie basse, accès à DDRA
HOR_CRA_AS0     equ $34             ; CA2 (AS) sortie basse, accès à PRA
HOR_CRA_AS1     equ $3C             ; CA2 (AS) sortie haute
HOR_PB_REPOS    equ $02             ; DS = 0, R/W = 1
HOR_PB_LIT      equ $03             ; DS = 1, R/W = 1
HOR_PB_ECR      equ $00             ; DS = 0, R/W = 0
HOR_PB_ECR_DS   equ $01             ; DS = 1, R/W = 0

Hor_Init:
    PSHS    A
    LDA     #$04
    STA     CRB                 ; d'abord ORB (après un reset, CRB = 0 :
    LDA     #HOR_PB_REPOS       ; PIADRB serait DDRB)
    STA     PIADRB              ; ORB : DS = 0, R/W = 1, avant les sorties
    CLR     CRB
    LDA     #$FF                ; port B en sorties : DS descend seul
    STA     DDRB
    LDA     #$04
    STA     CRB
    LDA     #HOR_CRA_DDR
    STA     CRA
    LDA     #$FF                ; port A en sorties
    STA     DDRA
    LDA     #HOR_CRA_AS0
    STA     CRA
    PULS    A,PC

; --- l'adresse A sur AD, puis une impulsion sur AS (DS est bas) ---
Hor_Adresse:
    PSHS    B
    STA     PIADRA
    LDB     #HOR_CRA_AS1
    STB     CRA
    LDB     #HOR_CRA_AS0
    STB     CRA                 ; front descendant : adresse verrouillée
    PULS    B,PC

Hor_Lit:
    PSHS    B
    BSR     Hor_Adresse
    LDB     #HOR_CRA_DDR
    STB     CRA
    CLR     DDRA                ; AD en entrées avant que la puce parle
    LDB     #HOR_CRA_AS0
    STB     CRA
    LDB     #HOR_PB_LIT
    STB     PIADRB              ; DS = 1 : la puce tient AD
    LDA     PIADRA
    LDB     #HOR_PB_REPOS
    STB     PIADRB              ; DS = 0 : elle relâche AD
    LDB     #HOR_CRA_DDR
    STB     CRA
    LDB     #$FF
    STB     DDRA                ; AD de nouveau en sorties
    LDB     #HOR_CRA_AS0
    STB     CRA
    PULS    B,PC

Hor_Ecrit:
    PSHS    A,B
    BSR     Hor_Adresse
    STB     PIADRA              ; la donnée
    LDB     #HOR_PB_ECR
    STB     PIADRB              ; R/W = 0, DS encore bas
    LDB     #HOR_PB_ECR_DS
    STB     PIADRB              ; DS = 1
    LDB     #HOR_PB_ECR
    STB     PIADRB              ; DS = 0 : écrit
    LDB     #HOR_PB_REPOS
    STB     PIADRB              ; R/W = 1
    PULS    A,B,PC

Hor_Etat:
    LDA     #HOR_REGD
    LBSR     Hor_Lit
    BITA    #$7F
    BEQ     HE_Ok
    ORCC    #1
    RTS
HE_Ok:
    ANDCC   #$FE
    RTS

; --- lit les 7 octets ; recommence tant que deux lectures diffèrent.
; Chacune attend d'abord UIP = 0 (la mise à jour, qui rend les octets
; indéfinis, ne commence que 244 µs plus tard ; une lecture en prend un
; peu plus, d'où la seconde : faite après une nouvelle attente de UIP = 0,
; elle ne peut pas chevaucher la même mise à jour) ---
Hor_LitDate:
    PSHS    A,B,X,Y             ; X en 2,S
HLD_Encore:
    LDX     2,S
    BSR     HLD_Une             ; dans le tampon de l'appelant
    LDX     #HorCopie
    BSR     HLD_Une             ; dans HorCopie
    LDY     2,S
    LDB     #7
HLD_Cmp:
    LDA     ,X+
    CMPA    ,Y+
    BNE     HLD_Encore
    DECB
    BNE     HLD_Cmp
    PULS    A,B,X,Y,PC

; une lecture des 7 octets dans ,X (X gardé)
HLD_Une:
    LDA     #HOR_REGA
    LBSR     Hor_Lit
    TSTA
    BMI     HLD_Une             ; UIP = 1 : attendre
    PSHS    X
    LDY     #HorRegs
HLD_Reg:
    LDA     ,Y+
    LBSR     Hor_Lit
    STA     ,X+
    CMPY    #HorRegs+7
    BNE     HLD_Reg
    PULS    X,PC

Hor_Regle:
    PSHS    A,B,X,Y
    LDA     #HOR_REGB
    LDB     #HOR_B_SET          ; plus de mise à jour pendant le réglage
    LBSR    Hor_Ecrit
    LDA     #HOR_REGA
    LDB     #HOR_A_32K
    LBSR    Hor_Ecrit
    LDY     #HorRegs
HR_Reg:
    LDA     ,Y+
    LDB     ,X+
    LBSR    Hor_Ecrit
    CMPY    #HorRegs+7
    BNE     HR_Reg
    LDA     #HOR_REGB
    LDB     #HOR_B_MARCHE       ; SET = 0 : l'horloge repart
    LBSR    Hor_Ecrit
    PULS    A,B,X,Y,PC

HorRegs         FCB 0,2,4,6,7,8,9   ; registres de HOR_SEC..HOR_AN
HorCopie        RMB 7
