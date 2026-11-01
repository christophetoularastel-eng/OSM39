; ===================================================================
; essai_sd.asm - Module d'essai de la carte SD (SPI matériel SD-KBD-SON),
;                chargé par TELE en page 1, $1000 (tools/tele/essai_sd.py)
; ===================================================================
; Points d'entrée (table de sauts en tête, appelés par TELE 'C') :
;   $1000 Init     : 80 coups /CS haut, CMD0, CMD8, ACMD41, CMD58, en lent.
;                    A = 0 si prête, sinon n° d'étape ; B = dernier R1.
;   $1003 Ctrl     : A -> SD_CTRL (bit 0 /CS, bit 1 rapide).
;   $1006 Lit      : secteur Arg -> X (512 octets). A = code, C = 1 échec.
;   $1009 Ecrit    : X (512 octets) -> secteur Arg, B = façon d'envoyer
;                    les données : 0 boucle serrée (11 accès au bus par
;                    octet), 1 un octet par Spi_Envoie (espacés), 2 tout
;                    en lent ; + 4 : pas d'octets de CRC écrits, les
;                    lectures de la trace donnent les coups d'horloge ;
;                    + 8 : CMD24 « à l'aveugle » : aucune lecture avant le
;                    jeton (4 x $FF écrits à la place de l'attente de R1) ;
;                    + 16 : les 4 premiers octets de données partent par
;                    des LECTURES (on voit ce que MOSI envoie alors).
;                    A = code, C = 1 échec ; Trace (16 octets), Occupe.
;   $100C Etat     : CMD13. A = R1, B = second octet, C = 1 sans réponse.
;   $100F Cmd      : A = commande, B = CRC, Arg ; A = R1, Quatre = les 4
;                    octets suivants.
; Variables à des adresses fixes ($1020...) : voir la fin du fichier ;
; essai_sd.py les lit dans la carte de l'édition de liens.
; ===================================================================
    include "../../bios/hardware.inc"
    include "../../bios/sysfunc.inc"

ATT_LENT        equ 60

    section .code

Entrees:
    JMP     Init
    JMP     Ctrl
    JMP     Lit
    JMP     Ecrit
    JMP     Etat
    JMP     Cmd_Brute
    FCB     0,0,0,0,0,0,0,0,0,0,0,0,0,0
; --- Variables ($1020) ---
V_Ctrl          FCB 0           ; $1020 copie de SD_CTRL
Arg             FCB 0,0,0,0     ; $1021
Quatre          FCB 0,0,0,0     ; $1025
Trace           FCB 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0     ; $1029
Occupe          FDB 0           ; $1031 trames d'occupation
Essais          FDB 0           ; $1033 ACMD41
Trame0          FDB 0           ; $1035

; -------------------------------------------------------------------
Ctrl:
    STA     V_Ctrl
    STA     SD_CTRL
    RTS

Spi_Envoie:
    STA     SD_DATA
    BRA     Spi_Attente
Spi_Recoit:
    LDA     SD_DATA
Spi_Attente:
    PSHS    B
    LDB     V_Ctrl
    BITB    #$02
    BNE     SA_Fin
    LDB     #ATT_LENT
SA_Tour:
    DECB
    BNE     SA_Tour
SA_Fin:
    PULS    B,PC

; A = commande, B = CRC, Arg. A = R1, C = 1 sans réponse en 10 octets.
Sd_Cmd:
    PSHS    B
    PSHS    A
    LDA     #$FF
    JSR     Spi_Envoie
    PULS    A
    ORA     #$40
    JSR     Spi_Envoie
    LDA     Arg
    JSR     Spi_Envoie
    LDA     Arg+1
    JSR     Spi_Envoie
    LDA     Arg+2
    JSR     Spi_Envoie
    LDA     Arg+3
    JSR     Spi_Envoie
    PULS    A
    JSR     Spi_Envoie
    LDB     #10
SC_R1:
    JSR     Spi_Recoit
    TSTA
    BPL     SC_Ok
    DECB
    BNE     SC_R1
    ORCC    #1
    RTS
SC_Ok:
    ANDCC   #$FE
    RTS

Lit4:
    PSHS    A,X
    LDX     #Quatre
    LDB     #4
L4_Oct:
    JSR     Spi_Recoit
    STA     ,X+
    DECB
    BNE     L4_Oct
    PULS    A,X,PC

Cmd_Brute:
    JSR     Sd_Cmd
    BCS     CB_Fin
    JSR     Lit4
    ANDCC   #$FE
CB_Fin:
    RTS

Arg_Zero:
    PSHS    D
    LDD     #0
    STD     Arg
    STD     Arg+2
    PULS    D,PC

; -------------------------------------------------------------------
Init:
    LDA     #$01
    JSR     Ctrl
    LDB     #10
IN_Hor:
    LDA     #$FF
    JSR     Spi_Envoie
    DECB
    BNE     IN_Hor
    LDA     #$00
    JSR     Ctrl
    JSR     Arg_Zero
    LDA     #0
    LDB     #$95
    JSR     Sd_Cmd
    TFR     A,B
    LDA     #1
    BCS     IN_Ko
    CMPB    #$01
    BNE     IN_Ko
    LDD     #$01AA
    STD     Arg+2
    LDA     #8
    LDB     #$87
    JSR     Sd_Cmd
    TFR     A,B
    LDA     #2
    BCS     IN_Ko
    CMPB    #$01
    BNE     IN_Ko
    JSR     Lit4
    LDD     #0
    STD     Essais
IN_41:
    LDD     Essais
    ADDD    #1
    STD     Essais
    CMPD    #2000
    BHI     IN_41Ko
    JSR     Arg_Zero
    LDA     #55
    LDB     #$65
    JSR     Sd_Cmd
    BCS     IN_41Ko
    LDD     #$4000
    STD     Arg
    LDA     #41
    LDB     #$77
    JSR     Sd_Cmd
    BCS     IN_41Ko
    TSTA
    BNE     IN_41
    JSR     Arg_Zero
    LDA     #58
    LDB     #$FD
    JSR     Sd_Cmd
    TFR     A,B
    LDA     #4
    BCS     IN_Ko
    TSTB
    BNE     IN_Ko
    JSR     Lit4
    CLRA
    ANDCC   #$FE
    RTS
IN_41Ko:
    TFR     A,B
    LDA     #3
IN_Ko:
    ORCC    #1
    RTS

; -------------------------------------------------------------------
; Lecture : secteur Arg -> X. A = code (R1, jeton, $FF), C = 1 échec.
Lit:
    PSHS    X
    LDA     #17
    LDB     #$01
    JSR     Sd_Cmd
    BCS     LI_Ko
    TSTA
    BNE     LI_Ko
    LDX     #4000
LI_Jeton:
    JSR     Spi_Recoit
    CMPA    #$FE
    BEQ     LI_Donnees
    CMPA    #$FF
    BNE     LI_Ko
    LEAX    -1,X
    BNE     LI_Jeton
    BRA     LI_Ko
LI_Donnees:
    PULS    X
    LDW     #512
    LDB     V_Ctrl
    BITB    #$02
    BEQ     LI_Lent
LI_Oct:
    LDA     SD_DATA
    STA     ,X+
    DECW
    BNE     LI_Oct
    BRA     LI_Crc
LI_Lent:
    JSR     Spi_Recoit
    STA     ,X+
    DECW
    BNE     LI_Lent
LI_Crc:
    JSR     Spi_Recoit
    JSR     Spi_Recoit
    CLRA
    ANDCC   #$FE
    RTS
LI_Ko:
    PULS    X
    ORCC    #1
    RTS

; -------------------------------------------------------------------
; Écriture : X -> secteur Arg, B = façon (0 serrée, 1 espacée, 2 lente).
Ecrit:
    STB     Facon
    PSHS    X
    BITB    #8
    BNE     EC_Aveugle
    LDA     #24
    LDB     #$01
    JSR     Sd_Cmd
    LBCS    EC_Ko
    TSTA
    LBNE    EC_Ko
    BRA     EC_Vit
EC_Aveugle:                     ; la commande, puis 4 $FF, rien de lu
    LDA     #$FF
    JSR     Spi_Envoie
    LDA     #$58
    JSR     Spi_Envoie
    LDA     Arg
    JSR     Spi_Envoie
    LDA     Arg+1
    JSR     Spi_Envoie
    LDA     Arg+2
    JSR     Spi_Envoie
    LDA     Arg+3
    JSR     Spi_Envoie
    LDA     #$01
    JSR     Spi_Envoie
    LDB     #4
    LDA     #$FF
EC_Av4:
    JSR     Spi_Envoie
    DECB
    BNE     EC_Av4
EC_Vit:
    LDA     V_Ctrl              ; vitesse d'origine, rendue après
    STA     Vit0
    LDB     Facon
    ANDB    #3
    CMPB    #2
    BNE     EC_Jeton
    ANDA    #$FD                ; tout en lent
    JSR     Ctrl
EC_Jeton:
    LDA     #$FF
    JSR     Spi_Envoie
    LDA     #$FE
    JSR     Spi_Envoie
    PULS    X
    LDW     #512
    LDB     Facon
    BITB    #16
    BEQ     EC_Mode
    LDB     #4                  ; 4 lectures à la place de 4 octets
EC_Lect:
    JSR     Spi_Recoit
    LEAX    1,X
    DECW
    DECB
    BNE     EC_Lect
EC_Mode:
    LDB     Facon
    ANDB    #3
    BNE     EC_Lent
EC_Oct:
    LDA     ,X+
    STA     SD_DATA
    DECW
    BNE     EC_Oct
    BRA     EC_Crc
EC_Lent:                        ; façons 1 et 2 : un appel par octet
    LDA     ,X+
    JSR     Spi_Envoie
    DECW
    BNE     EC_Lent
EC_Crc:
    LDB     Facon
    BITB    #4
    BNE     EC_SansCrc
    LDA     #$FF
    JSR     Spi_Envoie
    JSR     Spi_Envoie
EC_SansCrc:
    LDD     #0
    STD     Occupe
    LDX     #Trace
    LDB     #16
EC_Trace:
    JSR     Spi_Recoit
    STA     ,X+
    DECB
    BNE     EC_Trace
    LDA     Vit0                ; vitesse d'origine pour la suite
    JSR     Ctrl
    LDX     #Trace
    LDB     #16
EC_Rep:
    LDA     ,X+
    CMPA    #$FF
    BNE     EC_RepLue
    DECB
    BNE     EC_Rep
    ORCC    #1
    RTS
EC_RepLue:
    TFR     A,B
    ANDB    #$1F
    CMPB    #$05
    BNE     EC_Err
    CMPX    #Trace+16
    BEQ     EC_Attend
    LDA     Trace+15
    BNE     EC_Fin
EC_Attend:
    LDD     vsync_tick
    STD     Trame0
    LDY     #8
EC_Tour:
    LDW     #0
EC_Occ:
    JSR     Spi_Recoit
    TSTA
    BNE     EC_Duree
    DECW
    BNE     EC_Occ
    LEAY    -1,Y
    BNE     EC_Tour
    BSR     EC_Mesure
    CLRA
    ORCC    #1
    RTS
EC_Duree:
    BSR     EC_Mesure
EC_Fin:
    CLRA
    ANDCC   #$FE
    RTS
EC_Mesure:
    LDD     vsync_tick
    SUBD    Trame0
    STD     Occupe
    RTS
EC_Err:
    ORCC    #1
    RTS
EC_Ko:
    PULS    X
    ORCC    #1
    RTS

; -------------------------------------------------------------------
Etat:
    JSR     Arg_Zero
    LDA     #13
    LDB     #$01
    JSR     Sd_Cmd
    BCS     ET_Fin
    PSHS    A
    JSR     Spi_Recoit
    TFR     A,B
    PULS    A
    ANDCC   #$FE
ET_Fin:
    RTS

Facon           FCB 0
Vit0            FCB 0
