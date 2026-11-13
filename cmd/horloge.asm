; ===================================================================
; HORLOGE.ASM - Lit ou règle l'horloge sauvegardée (MC146818 sur le PIA)
; Usage: HORLOGE                          affiche la date et l'heure
;        HORLOGE JJ/MM/AAAA HH:MM[:SS]    règle (AA accepté pour l'année)
; Charge: page 1, $0000. Pilote : lib/horloge.asm.
; Années 2000-2099 ; le jour de la semaine est calculé au réglage.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

    section .code

Start:
    JSR     Hor_Init
    JSR     Hor_Etat
    LBCS    Absente
    TSTA
    BMI     Args                ; VRT = 1 : la pile a tenu
    LDX     #MsgPile
    JSR     [table_function_ram+sys_PrintString]
Args:
    LDA     argc
    CMPA    #1
    BEQ     Affiche
    CMPA    #3
    LBEQ    Reglage
    LDX     #MsgUsage
    JMP     [table_function_ram+sys_PrintString]

; ------------------------------------------------------------------
Affiche:
    LDA     #HOR_REGA
    JSR     Hor_Lit
    ANDA    #$70
    CMPA    #HOR_A_32K          ; diviseur arrêté ou pas pour 32 kHz
    BNE     NonReglee
    LDA     #HOR_REGB
    JSR     Hor_Lit
    ANDA    #$86                ; SET, binaire, 24 h
    CMPA    #HOR_B_MARCHE
    BNE     NonReglee
    LDX     #Date
    JSR     Hor_LitDate
    LDB     HOR_JS,X
    DECB
    CMPB    #7
    BLO     JS_Ok
    LDB     #7                  ; "?"
JS_Ok:
    LDY     #NomsJours
    ASLB
    LDX     B,Y
    JSR     [table_function_ram+sys_PrintString]
    LDA     #' '
    JSR     [table_function_ram+sys_PrintChar]
    LDX     #Date
    LDA     HOR_JOUR,X
    LDB     #'/'
    BSR     DeuxCh
    LDA     HOR_MOIS,X
    LDB     #'/'
    BSR     DeuxCh
    LDA     #$20                ; "20" puis l'année
    JSR     [table_function_ram+sys_PrintHexChar]
    LDA     HOR_AN,X
    LDB     #' '
    BSR     DeuxCh
    LDA     HOR_HEURE,X
    LDB     #':'
    BSR     DeuxCh
    LDA     HOR_MIN,X
    LDB     #':'
    BSR     DeuxCh
    LDA     HOR_SEC,X
    JSR     [table_function_ram+sys_PrintHexChar]
    JMP     [table_function_ram+sys_PrintCRLF]

; A = deux chiffres BCD, puis le caractère B
DeuxCh:
    PSHS    B
    JSR     [table_function_ram+sys_PrintHexChar]
    PULS    A
    JMP     [table_function_ram+sys_PrintChar]

NonReglee:
    LDX     #MsgNonReglee
    JMP     [table_function_ram+sys_PrintString]
Absente:
    LDX     #MsgAbsente
    JMP     [table_function_ram+sys_PrintString]
Mauvais:
    LDX     #MsgMauvais
    JMP     [table_function_ram+sys_PrintString]

; ------------------------------------------------------------------
Reglage:
    ; --- la date : J/M/AA ou J/M/AAAA ---
    LDX     >argv+2
    BSR     Champ2
    BCS     Mauvais
    STA     Jour
    LDA     ,X+
    CMPA    #'/'
    BNE     Mauvais
    BSR     Champ2
    BCS     Mauvais
    STA     Mois
    LDA     ,X+
    CMPA    #'/'
    BNE     Mauvais
    LBSR    Nombre
    BCS     Mauvais
    LDA     Chiffres
    CMPA    #2
    BEQ     An2
    CMPA    #4
    BNE     Mauvais
    LDD     Valeur
    SUBD    #2000
    BCS     Mauvais
    CMPD    #99
    BHI     Mauvais
    BRA     AnOk
An2:
    LDB     Valeur+1
AnOk:
    STB     An
    TST     ,X
    BNE     Mauvais
    ; --- l'heure : H:M ou H:M:S ---
    LDX     >argv+4
    BSR     Champ2
    BCS     Mauvais
    STA     Heure
    LDA     ,X+
    CMPA    #':'
    BNE     Mauvais
    BSR     Champ2
    BCS     Mauvais
    STA     Minute
    CLR     Seconde
    LDA     ,X+
    BEQ     Bornes
    CMPA    #':'
    BNE     Mauvais
    BSR     Champ2
    BCS     Mauvais
    STA     Seconde
    TST     ,X
    BNE     Mauvais
    BRA     Bornes

; 1 ou 2 chiffres -> A (C = 1 sinon)
Champ2:
    LBSR    Nombre
    BCS     C2_Fin
    LDA     Chiffres
    CMPA    #2
    BHI     C2_Err
    LDA     Valeur+1
    ANDCC   #$FE
C2_Fin:
    RTS
C2_Err:
    ORCC    #1
    RTS

Bornes:
    LDA     Heure
    CMPA    #23
    LBHI    Mauvais
    LDA     Minute
    CMPA    #59
    LBHI    Mauvais
    LDA     Seconde
    CMPA    #59
    LBHI    Mauvais
    LDB     Mois
    DECB
    CMPB    #12
    LBHS    Mauvais             ; mois 0 ou > 12
    LDX     #JoursMois
    LDA     B,X                 ; jours du mois
    CMPB    #1
    BNE     JM_Ok
    LDB     An
    ANDB    #3
    BNE     JM_Ok
    INCA                        ; 29 février (2000 était bissextile)
JM_Ok:
    LDB     Jour
    LBEQ    Mauvais
    PSHS    A
    CMPB    ,S+
    LBHI    Mauvais
    ; --- jour de la semaine (Sakamoto) : a = an - (mois < 3) ;
    ; a + a/4 + T[mois-1] + jour, modulo 7, 0 = dimanche. Pour 1999
    ; (janvier-février 2000), a = 27 : même résultat modulo 7 ---
    LDA     An
    LDB     Mois
    CMPB    #3
    BHS     JS_An
    SUBA    #1
    BCC     JS_An
    LDA     #27
JS_An:
    TFR     A,B
    LSRB
    LSRB
    PSHS    B
    ADDA    ,S+
    LDX     #TabJS
    LDB     Mois
    DECB
    ADDA    B,X
    ADDA    Jour
JS_Mod:
    CMPA    #7
    BLO     JS_Fin
    SUBA    #7
    BRA     JS_Mod
JS_Fin:
    INCA                        ; 1 = dimanche
    STA     Date+HOR_JS
    ; --- en BCD dans Date, puis réglage ---
    LDA     Seconde
    BSR     EnBcd
    STA     Date+HOR_SEC
    LDA     Minute
    BSR     EnBcd
    STA     Date+HOR_MIN
    LDA     Heure
    BSR     EnBcd
    STA     Date+HOR_HEURE
    LDA     Jour
    BSR     EnBcd
    STA     Date+HOR_JOUR
    LDA     Mois
    BSR     EnBcd
    STA     Date+HOR_MOIS
    LDA     An
    BSR     EnBcd
    STA     Date+HOR_AN
    LDX     #Date
    JSR     Hor_Regle
    LBRA    Affiche

; A (0-99) -> BCD
EnBcd:
    CLRB
EB_Diz:
    CMPA    #10
    BLO     EB_Fin
    SUBA    #10
    ADDB    #$10
    BRA     EB_Diz
EB_Fin:
    PSHS    B
    ADDA    ,S+
    RTS

; des chiffres en ,X -> Valeur (Chiffres = leur nombre, 1-4), X après eux ;
; C = 1 s'il n'y en a aucun ou plus de 4
Nombre:
    CLR     Chiffres
    LDD     #0
    STD     Valeur
NB_Car:
    LDA     ,X
    SUBA    #'0'
    BLO     NB_Fin
    CMPA    #9
    BHI     NB_Fin
    PSHS    A
    LDD     Valeur              ; Valeur * 10 + chiffre
    ASLB
    ROLA
    ASLB
    ROLA
    ADDD    Valeur
    ASLB
    ROLA
    ADDB    ,S+
    ADCA    #0
    STD     Valeur
    LEAX    1,X
    INC     Chiffres
    LDA     Chiffres
    CMPA    #4
    BLS     NB_Car
    ORCC    #1
    RTS
NB_Fin:
    TST     Chiffres
    BEQ     NB_Err
    ANDCC   #$FE
    RTS
NB_Err:
    ORCC    #1
    RTS

    include "../lib/horloge.asm"

JoursMois:  FCB 31,28,31,30,31,30,31,31,30,31,30,31
TabJS:      FCB 0,3,2,5,0,3,5,1,4,6,2,4
NomsJours:  FDB Dim,Lun,Mar,Mer,Jeu,Ven,Sam,Inconnu
Dim:        FCN "dimanche"
Lun:        FCN "lundi"
Mar:        FCN "mardi"
Mer:        FCN "mercredi"
Jeu:        FCN "jeudi"
Ven:        FCN "vendredi"
Sam:        FCN "samedi"
Inconnu:    FCN "?"

MsgUsage:   FCC "Usage: HORLOGE [JJ/MM/AAAA HH:MM[:SS]]"
            FCB $0a,$0D,0
MsgAbsente: FCC "Pas de r"
            FCB $82
            FCC "ponse de l'horloge (carte RTC sur le PIA ?)"
            FCB $0a,$0D,0
MsgPile:    FCC "La pile de l'horloge a l"
            FCB $83
            FCC "ch"
            FCB $82
            FCC " : date perdue."
            FCB $0a,$0D,0
MsgNonReglee:
            FCC "Horloge pas r"
            FCB $82
            FCC "gl"
            FCB $82
            FCC "e : HORLOGE JJ/MM/AAAA HH:MM[:SS]"
            FCB $0a,$0D,0
MsgMauvais: FCC "Date ou heure invalide."
            FCB $0a,$0D,0

Jour:       RMB 1
Mois:       RMB 1
An:         RMB 1
Heure:      RMB 1
Minute:     RMB 1
Seconde:    RMB 1
Chiffres:   RMB 1
Valeur:     RMB 2
Date:       RMB 7
