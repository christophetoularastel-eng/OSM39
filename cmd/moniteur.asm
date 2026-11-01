; ===================================================================
; MONITEUR.ASM — Mémoire, appels et rapport du dernier TRAP
; Usage: MONITEUR       (programme console, page 1, $0000)
; L'EPROM ne garde qu'un SECOURS (LOAD, RUN, BOOT) : le reste est ici.
; Commandes (valeurs en hexadécimal, adresse [page:]aaaa, page 0 par
; défaut ; au-delà de $7FFF la page ne compte pas) :
;   M [p:]aaaa          128 octets, en hexa et en caractères
;   E [p:]aaaa xx yy..  écrit ces octets à partir de aaaa
;   G [p:]aaaa          appelle aaaa dans la page p (FAR_CALL) ; registres
;                       au retour
;   R                   le rapport du dernier TRAP (bios/IT.asm)
;   Q                   quitter        ?  l'aide
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

    section .code

Start:
    LDX     #MsgTitre
    JSR     [table_function_ram+sys_PrintString]
Invite:
    LDX     #MsgInvite
    JSR     [table_function_ram+sys_PrintString]
    JSR     [table_function_ram+sys_read_line]   ; majuscules, NUL final
    JSR     [table_function_ram+sys_PrintCRLF]
    LDX     #input_buffer
    JSR     Blancs
    LDA     ,X+
    BEQ     Invite
    LDY     #Commandes
Cherche:
    LDB     ,Y
    BEQ     Inconnue
    CMPA    ,Y
    BEQ     Trouve
    LEAY    3,Y
    BRA     Cherche
Trouve:
    JSR     [1,Y]
    BRA     Invite
Inconnue:
    LDX     #MsgAide
    JSR     [table_function_ram+sys_PrintString]
    BRA     Invite

Commandes:
    FCB     'M
    FDB     Cmd_M
    FCB     'E
    FDB     Cmd_E
    FCB     'G
    FDB     Cmd_G
    FCB     'R
    FDB     Cmd_R
    FCB     'Q
    FDB     Cmd_Q
    FCB     '?
    FDB     Cmd_Aide
    FCB     0

Cmd_Q:
    LEAS    2,S                 ; (l'adresse de retour vers Invite)
    RTS

Cmd_Aide:
    LDX     #MsgAide
    JMP     [table_function_ram+sys_PrintString]

; -------------------------------------------------------------------
; Lecture des arguments. X avance dans input_buffer.
; -------------------------------------------------------------------
; Blancs - saute les espaces.
Blancs:
    LDA     ,X
    CMPA    #' '
    BNE     Bl_Fin
    LEAX    1,X
    BRA     Blancs
Bl_Fin:
    RTS

; LitHex - un nombre hexadécimal : D. C=1 s'il n'y a pas de chiffre.
LitHex:
    JSR     Blancs
    LDD     #0
    STD     Val
    CLR     NbChiffres
LH_Lp:
    LDA     ,X
    SUBA    #'0'
    BLO     LH_Fin
    CMPA    #9
    BLS     LH_Ok
    SUBA    #'A'-'0'-10
    CMPA    #10
    BLO     LH_Fin
    CMPA    #15
    BHI     LH_Fin
LH_Ok:
    LEAX    1,X
    INC     NbChiffres
    LSL     Val+1               ; Val = Val * 16 + A
    ROL     Val
    LSL     Val+1
    ROL     Val
    LSL     Val+1
    ROL     Val
    LSL     Val+1
    ROL     Val
    ORA     Val+1
    STA     Val+1
    BRA     LH_Lp
LH_Fin:
    LDD     Val
    TST     NbChiffres
    BEQ     LH_Rien
    ANDCC   #$FE
    RTS
LH_Rien:
    ORCC    #1
    RTS

; LitAdresse - [p:]aaaa : Page, Adr. C=1 si absente ou page > 3.
LitAdresse:
    CLR     Page
    JSR     LitHex
    BCS     LA_Ret
    PSHS    D
    LDA     ,X
    CMPA    #':'
    PULS    D                   ; (PULS ne touche pas les drapeaux)
    BNE     LA_Seule
    LEAX    1,X
    CMPD    #3
    BHI     LA_Err
    STB     Page
    JSR     LitHex
    BCS     LA_Ret
LA_Seule:
    STD     Adr
    ANDCC   #$FE
LA_Ret:
    RTS
LA_Err:
    ORCC    #1
    RTS

ErrArg:
    LDX     #MsgArg
    JMP     [table_function_ram+sys_PrintString]

; -------------------------------------------------------------------
; M [p:]aaaa : 8 lignes de 16 octets
; -------------------------------------------------------------------
Cmd_M:
    JSR     LitAdresse
    BCS     ErrArg
    LDD     Adr
    LDU     #Tampon
    LDY     #128
    JSR     Lire                ; Tampon = 128 octets de Page:Adr
    LDU     #Tampon
    LDB     #8
M_Ligne:
    PSHS    B
    LDA     Page
    JSR     [table_function_ram+sys_PrintHexChar]
    LDA     #':'
    JSR     [table_function_ram+sys_PrintChar]
    LDD     Adr
    JSR     [table_function_ram+sys_PrintHexWord]
    LDA     #' '
    JSR     [table_function_ram+sys_PrintChar]
    LDB     #16
    PSHS    U
M_Hexa:
    LDA     #' '
    JSR     [table_function_ram+sys_PrintChar]
    LDA     ,U+
    JSR     [table_function_ram+sys_PrintHexChar]
    DECB
    BNE     M_Hexa
    PULS    U
    LDA     #' '
    JSR     [table_function_ram+sys_PrintChar]
    LDB     #16
M_Car:
    LDA     ,U+
    CMPA    #' '
    BLO     M_Point
    CMPA    #$7E
    BLS     M_Ecrit
M_Point:
    LDA     #'.'
M_Ecrit:
    JSR     [table_function_ram+sys_PrintChar]
    DECB
    BNE     M_Car
    JSR     [table_function_ram+sys_PrintCRLF]
    LDD     Adr
    ADDD    #16
    STD     Adr
    PULS    B
    DECB
    BNE     M_Ligne
    RTS

; Lire - Y octets de Page:D vers U (page du MONITEUR).
Lire:
    CMPD    #$8000
    BHS     Li_Commun
    PSHS    D
    TFR     U,D                 ; (FarRead : Y = destination)
    TFR     D,W
    PULS    X                   ; X = source
    TFR     Y,U                 ; U = taille
    TFR     W,Y                 ; Y = destination
    LDA     Page
    LDB     current_page
    JMP     [table_function_ram+sys_FarRead]
Li_Commun:                      ; RAM système, vidéo, EPROM : lecture directe
    TFR     D,X
Li_Lp:
    LDA     ,X+
    STA     ,U+
    LEAY    -1,Y
    BNE     Li_Lp
    RTS

; -------------------------------------------------------------------
; E [p:]aaaa xx yy ... : écrit les octets donnés
; -------------------------------------------------------------------
Cmd_E:
    CLR     NbOctets
    JSR     LitAdresse
    LBCS    ErrArg
    LDU     #Tampon
    CLRB
E_Octet:
    PSHS    U
    JSR     LitHex
    PULS    U
    BCS     E_Fini
    CMPD    #$FF
    LBHI    ErrArg
    STB     ,U+
    INC     NbOctets
    LDB     NbOctets
    CMPB    #64
    BLO     E_Octet
E_Fini:
    LDB     NbOctets
    LBEQ    ErrArg
    CLR     NbOctets
    CLRA
    TFR     D,U                 ; U = taille
    LDD     Adr
    CMPD    #$8000
    BHS     E_Commun
    TFR     D,Y                 ; Y = destination
    LDX     #Tampon
    LDA     Page
    LDB     current_page
    JMP     [table_function_ram+sys_FarWrite]
E_Commun:
    TFR     D,Y
    LDX     #Tampon
E_Lp:
    LDA     ,X+
    STA     ,Y+
    LEAU    -1,U
    CMPU    #0
    BNE     E_Lp
    RTS

; -------------------------------------------------------------------
; G [p:]aaaa : appel par la passerelle entre pages, puis les registres
; -------------------------------------------------------------------
Cmd_G:
    JSR     LitAdresse
    LBCS    ErrArg
    LDA     Page
    LDX     Adr
    JSR     [table_function_ram+sys_Far_Call]
    PSHS    CC,D,X,Y,U
    LDX     #MsgRetour
    JSR     [table_function_ram+sys_PrintString]
    LDX     #Noms_Ret
    LDA     #'A'
    JSR     Nom
    LDA     1,S
    JSR     [table_function_ram+sys_PrintHexChar]
    JSR     NomSuiv
    LDA     2,S
    JSR     [table_function_ram+sys_PrintHexChar]
    JSR     NomSuiv
    LDD     3,S
    JSR     [table_function_ram+sys_PrintHexWord]
    JSR     NomSuiv
    LDD     5,S
    JSR     [table_function_ram+sys_PrintHexWord]
    JSR     NomSuiv
    LDD     7,S
    JSR     [table_function_ram+sys_PrintHexWord]
    JSR     NomSuiv
    LDA     0,S
    JSR     Drapeaux
    JSR     [table_function_ram+sys_PrintCRLF]
    LEAS    9,S
    RTS

; Nom (X = suite de chaînes NUL) affiche la première ; NomSuiv la
; suivante ; NomSaute la passe sans l'afficher. Le pointeur est en
; mémoire (NomPtr) : les routines d'affichage du BIOS peuvent changer X.
Nom:
    STX     NomPtr
NomSuiv:
    PSHS    A,X
    LDX     NomPtr
NS_Lp:
    LDA     ,X+
    BEQ     NS_Fin
    JSR     [table_function_ram+sys_PrintChar]
    BRA     NS_Lp
NS_Fin:
    STX     NomPtr
    PULS    A,X,PC
NomSaute:
    PSHS    A,X
    LDX     NomPtr
NSa_Lp:
    LDA     ,X+
    BNE     NSa_Lp
    BRA     NS_Fin

; Drapeaux - A = CC : les lettres EFHINZVC (un '.' pour un 0).
Drapeaux:
    PSHS    A,B,X
    LDX     #Lettres_CC
    LDB     #8
Dr_Lp:
    LDA     ,X+
    LSL     0,S
    BCS     Dr_Ecrit
    LDA     #'.'
Dr_Ecrit:
    JSR     [table_function_ram+sys_PrintChar]
    DECB
    BNE     Dr_Lp
    PULS    A,B,X,PC

; -------------------------------------------------------------------
; R : le rapport du dernier TRAP (trap_frame, trap_info : bios/ram.asm)
; -------------------------------------------------------------------
Cmd_R:
    LDA     trap_info
    CMPA    #$A5
    BEQ     R_Oui
    LDX     #MsgPasTrap
    JMP     [table_function_ram+sys_PrintString]
R_Oui:
    LDX     #Noms_Trap
    JSR     Nom                 ; "Dernier TRAP : PC="
    LDD     trap_frame+12
    JSR     [table_function_ram+sys_PrintHexWord]
    JSR     NomSuiv             ; "  page "
    LDA     trap_info+1
    JSR     [table_function_ram+sys_PrintHexChar]
    JSR     NomSuiv             ; "  CC="
    LDA     trap_frame
    JSR     Drapeaux
    JSR     NomSuiv             ; CRLF "A="
    LDA     trap_frame+1
    JSR     [table_function_ram+sys_PrintHexChar]
    JSR     NomSuiv             ; " B="
    LDA     trap_frame+2
    JSR     [table_function_ram+sys_PrintHexChar]
    JSR     NomSuiv             ; " W="
    LDD     trap_frame+3
    JSR     [table_function_ram+sys_PrintHexWord]
    JSR     NomSuiv             ; " DP="
    LDA     trap_frame+5
    JSR     [table_function_ram+sys_PrintHexChar]
    JSR     NomSuiv             ; " X="
    LDD     trap_frame+6
    JSR     [table_function_ram+sys_PrintHexWord]
    JSR     NomSuiv             ; " Y="
    LDD     trap_frame+8
    JSR     [table_function_ram+sys_PrintHexWord]
    JSR     NomSuiv             ; " U="
    LDD     trap_frame+10
    JSR     [table_function_ram+sys_PrintHexWord]
    JSR     NomSuiv             ; " S="
    LDD     trap_frame+14
    ADDD    #14                 ; S d'avant le TRAP (la frame est poussée)
    JSR     [table_function_ram+sys_PrintHexWord]
    JSR     NomSuiv             ; CRLF "Pile :"
    PSHS    X
    LDX     #trap_frame+16
    LDB     #5
R_Pile:
    LDA     #' '
    JSR     [table_function_ram+sys_PrintChar]
    LDD     ,X++
    JSR     [table_function_ram+sys_PrintHexWord]
    DECB
    BNE     R_Pile
    PULS    X
    JSR     NomSuiv             ; CRLF "Octets a PC-4 :"
    PSHS    X
    LDX     #trap_info+15
    LDB     #16
R_Op:
    LDA     #' '
    JSR     [table_function_ram+sys_PrintChar]
    LDA     ,X+
    JSR     [table_function_ram+sys_PrintHexChar]
    DECB
    BNE     R_Op
    PULS    X
    JSR     NomSuiv             ; CRLF "Video : page "
    LDA     trap_info+2
    JSR     [table_function_ram+sys_PrintHexChar]
    JSR     NomSuiv             ; " debut="
    LDD     trap_info+3
    JSR     [table_function_ram+sys_PrintHexWord]
    JSR     NomSuiv             ; " curseur="
    LDD     trap_info+5
    JSR     [table_function_ram+sys_PrintHexWord]
    JSR     NomSuiv             ; " tampon="
    LDA     trap_frame+27
    JSR     [table_function_ram+sys_PrintHexChar]
    LDA     #'/'
    JSR     [table_function_ram+sys_PrintChar]
    LDA     trap_frame+28
    JSR     [table_function_ram+sys_PrintHexChar]
    JSR     NomSuiv             ; " saisie="
    LDD     trap_info+11
    JSR     [table_function_ram+sys_PrintHexWord]
    LDA     #'/'
    JSR     [table_function_ram+sys_PrintChar]
    LDD     trap_info+13
    JSR     [table_function_ram+sys_PrintHexWord]
    JSR     NomSuiv             ; CRLF "IRQ VSYNC : "
    LDD     trap_info+7
    CMPD    trap_info+9
    BEQ     R_Morte
    JSR     NomSuiv             ; "vivante"
    BRA     R_Fin
R_Morte:
    JSR     NomSaute            ; (pas "vivante")
    JSR     NomSuiv             ; "ARRETEE (l'ecran ne se mettait plus a jour)"
R_Fin:
    JMP     [table_function_ram+sys_PrintCRLF]

; -------------------------------------------------------------------
Noms_Ret:
    FCN     " A="
    FCN     " B="
    FCN     " X="
    FCN     " Y="
    FCN     " U="
    FCN     " CC="
Noms_Trap:
    FCN     "Dernier TRAP : PC="
    FCN     "  page "
    FCN     "  CC="
    FCB     $0A,$0D
    FCN     "A="
    FCN     " B="
    FCN     " W="
    FCN     " DP="
    FCN     " X="
    FCN     " Y="
    FCN     " U="
    FCN     " S="
    FCB     $0A,$0D
    FCN     "Pile :"
    FCB     $0A,$0D
    FCN     "Octets a PC-4 :"
    FCB     $0A,$0D
    FCN     "Video : page "
    FCN     " debut="
    FCN     " curseur="
    FCN     " tampon="
    FCN     " saisie="
    FCB     $0A,$0D
    FCN     "IRQ VSYNC : "
    FCN     "vivante"
    FCN     "ARRETEE (l'ecran ne se mettait plus a jour)"
Lettres_CC:
    FCC     "EFHINZVC"

MsgTitre:
    FCB     $0A,$0D
    FCC     "MONITEUR  (? : aide)"
    FCB     $0A,$0D,0
MsgInvite:
    FCB     $0A,$0D
    FCN     "MON>"
MsgAide:
    FCC     "M [p:]aaaa : memoire   E [p:]aaaa xx yy.. : ecrire"
    FCB     $0A,$0D
    FCC     "G [p:]aaaa : appeler   R : dernier TRAP   Q : quitter"
    FCB     $0A,$0D
    FCC     "(hexadecimal ; page 0 par defaut, ignoree au-dela de 7FFF)"
    FCB     $0A,$0D,0
MsgArg:
    FCC     "Argument invalide (? : aide)"
    FCB     $0A,$0D,0
MsgRetour:
    FCN     "Retour :"
MsgPasTrap:
    FCC     "Aucun TRAP depuis le dernier reset."
    FCB     $0A,$0D,0

NomPtr:     RMB 2
Val:        RMB 2
NbChiffres: RMB 1
NbOctets:   RMB 1
Page:       RMB 1
Adr:        RMB 2
Tampon:     RMB 128
