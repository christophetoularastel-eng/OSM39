; ===================================================================
; SD.asm - Carte SD sur le SPI matériel de la carte SD-KBD-SON
; ===================================================================
; Registres (hardware.inc) :
;   SD_CTRL ($A140, écriture seule) : bit 0 = /CS (1 : carte libre),
;     bit 1 = vitesse (0 : E/16, ~115 kHz ; 1 : E, 1,8432 MHz).
;     Sa copie est sd_ctrl (le registre ne se relit pas).
;   SD_DATA ($A148) : écrire envoie l'octet ; lire rend l'octet reçu au
;     transfert PRÉCÉDENT et lance un transfert qui RENVOIE cet octet à
;     la carte (mesuré le 30 oct. 2026 : le 165 se charge aussi en
;     lecture). Sans effet quand la carte parle ; mais après le R1 de
;     CMD24, un 00 renvoyé serait pris pour le début du bloc : CMD24 part
;     donc « à l'aveugle » (SD_WriteBlock), sans lecture avant le jeton.
; Pas de bit « occupé » : 9 cycles de bus au moins entre deux accès en
; rapide (les boucles en font plus), 150 en lent (Spi_Attente).
; L'init se fait en lent ; ensuite tout est en rapide.
;
; Contrat (inchangé depuis le SPI logiciel) :
;   Init_SD_Card : C = 0 carte prête, C = 1 pas de carte ou muette ;
;     chaque attente est bornée, l'écho $AA de CMD8 prouve une vraie
;     carte (v2, SDHC/SDXC : adresses en secteurs).
;   SD_ReadBlock  : secteur BlockAddr -> SD_BUFFER. A = 0 succès,
;     $E1 R1 de CMD17, $E2 pas de jeton.
;   SD_WriteBlock : SD_BUFFER -> secteur BlockAddr. A = 0 succès,
;     $E3 pas de réponse de données (CMD24 refusé), $E4 bloc refusé,
;     $E5 toujours occupée.
; ===================================================================

    include "hardware.inc"

    import  buffer
    import  sd_ctrl
    import  SD_BUFFER
    import  BlockAddr
    import  CMD17_Packet
    import  CMD24_Packet

    export Init_SD_Card
    export SD_Deselect
    export SD_Select
    export SD_ReadBlock
    export SD_WriteBlock

CTRL_RAPIDE     equ $02
ATT_LENT        equ 60          ; tours de DECB/BNE : > 150 cycles par octet

    section .code

; -------------------------------------------------------------------
; Init_SD_Card - en lent : 80 coups /CS haut, CMD0, CMD8, ACMD41 ;
; puis rapide, carte libérée.
; -------------------------------------------------------------------
Init_SD_Card:
    LDA     #$01                ; lent, carte libre
    JSR     Sd_Ctrl
    LDB     #10
Wakeup_Loop:
    JSR     Spi_FF
    DECB
    BNE     Wakeup_Loop
    JSR     SD_Select
    LDX     #CMD0_Packet
    JSR     SD_Commande
    CMPA    #$01
    BNE     Init_Echec
    LDX     #CMD8_Packet
    JSR     SD_Commande
    CMPA    #$01
    BNE     Init_Echec
    LDX     #buffer             ; R7 : 00 00 01 AA
    LDB     #4
cmd8_suite:
    JSR     Spi_Recoit
    STA     ,X+
    DECB
    BNE     cmd8_suite
    CMPA    #$AA                ; l'écho de CMD8 : une vraie carte
    BNE     Init_Echec
    LDD     #1000               ; ACMD41 : 1000 essais au plus
    STD     buffer+8
cmd41_ko:
    LDD     buffer+8
    SUBD    #1
    STD     buffer+8
    BEQ     Init_Echec
    LDX     #CMD55_Packet
    JSR     SD_Commande
    LDX     #ACMD41_Packet
    JSR     SD_Commande
    TSTA
    BNE     cmd41_ko
    LDA     #CTRL_RAPIDE+1      ; prête : rapide, carte libre
    JSR     Sd_Ctrl
    JSR     SD_Deselect
    ANDCC   #%11111110
    RTS
Init_Echec:
    JSR     SD_Deselect
    ORCC    #%00000001
    RTS

; -------------------------------------------------------------------
; Sélection : /CS bas, un octet de garde ; libération : un octet, /CS
; haut, un octet (la carte relâche MISO). La vitesse ne change pas.
; -------------------------------------------------------------------
SD_Select:
    JSR     Spi_FF
    LDA     sd_ctrl
    ANDA    #$FE
    BRA     SDS_Fin
SD_Deselect:
    JSR     Spi_FF
    LDA     sd_ctrl
    ORA     #$01
SDS_Fin:
    JSR     Sd_Ctrl
    BRA     Spi_FF

Sd_Ctrl:
    STA     sd_ctrl
    STA     SD_CTRL
    RTS

; -------------------------------------------------------------------
; Octets SPI. Spi_Envoie : A envoyé, A et B préservés. Spi_Recoit : A =
; octet reçu au transfert précédent. Spi_Attente laisse finir le
; transfert lancé (rien à faire en rapide : l'appel et le retour durent
; plus de 9 cycles).
; -------------------------------------------------------------------
Spi_FF:
    LDA     #$FF
Spi_Envoie:
    STA     SD_DATA
    BRA     Spi_Attente
Spi_Recoit:
    LDA     SD_DATA
Spi_Attente:
    PSHS    B
    LDB     sd_ctrl
    BITB    #CTRL_RAPIDE
    BNE     SA_Fin
    LDB     #ATT_LENT
SA_Tour:
    DECB
    BNE     SA_Tour
SA_Fin:
    PULS    B,PC

; -------------------------------------------------------------------
; SD_Commande - X = paquet de 6 octets ; A = R1 (ou $FF : pas de
; réponse en 10 octets). Détruit B et X.
; -------------------------------------------------------------------
SD_Commande:
    JSR     Spi_FF              ; garde
    LDB     #6
SC_Octet:
    LDA     ,X+
    JSR     Spi_Envoie
    DECB
    BNE     SC_Octet
    LDB     #10
SC_R1:
    JSR     Spi_Recoit
    TSTA
    BPL     SC_Fin              ; bit 7 = 0 : c'est R1
    DECB
    BNE     SC_R1
SC_Fin:
    RTS

; Copie BlockAddr dans l'argument du paquet X (octets 1-4).
Sd_Adresse:
    LDD     BlockAddr
    STD     1,X
    LDD     BlockAddr+2
    STD     3,X
    RTS

; -------------------------------------------------------------------
; SD_ReadBlock - secteur BlockAddr -> SD_BUFFER
; -------------------------------------------------------------------
SD_ReadBlock:
    LDX     #CMD17_Packet
    LDA     #$51
    STA     ,X
    LDA     #$01
    STA     5,X
    BSR     Sd_Adresse
    JSR     SD_Select
    JSR     SD_Commande
    TSTA
    BNE     Error_R1_Response
    LDY     #20000              ; jeton : ~400 ms (la norme : 100 ms)
Wait_Token_Loop:
    JSR     Spi_Recoit
    CMPA    #$FE
    BEQ     Token_Received
    LEAY    -1,Y
    BNE     Wait_Token_Loop
    LDA     #$E2
    BRA     SD_Fin
Token_Received:
    LDX     #SD_BUFFER
    LDW     #512
Read_512_Loop:                  ; 11 accès au bus par tour, au moins
    LDA     SD_DATA
    STA     ,X+
    DECW
    BNE     Read_512_Loop
    JSR     Spi_Recoit          ; CRC
    JSR     Spi_Recoit
    CLRA
    BRA     SD_Fin
Error_R1_Response:
    LDA     #$E1
SD_Fin:                         ; A = code, carte libérée
    PSHS    A
    JSR     SD_Deselect
    PULS    A,PC

    section .code
; -------------------------------------------------------------------
; SD_WriteBlock - SD_BUFFER -> secteur BlockAddr. CMD24, puis 8 x $FF
; écrits (R1 passe pendant ces octets, sans être lu : voir l'en-tête),
; jeton, données, CRC, réponse de données, attente de fin d'écriture.
; -------------------------------------------------------------------
SD_WriteBlock:
    LDX     #CMD24_Packet
    LDA     #$58
    STA     ,X
    LDA     #$01
    STA     5,X
    JSR     Sd_Adresse
    JSR     SD_Select
    JSR     Spi_FF              ; garde
    LDB     #6
WB_Cmd:
    LDA     ,X+
    JSR     Spi_Envoie
    DECB
    BNE     WB_Cmd
    LDB     #8                  ; NCR : R1 dans ces 8 octets, non lu
WB_Ncr:
    JSR     Spi_FF
    DECB
    BNE     WB_Ncr
    LDA     #$FE                ; jeton
    JSR     Spi_Envoie
    LDX     #SD_BUFFER
    LDW     #512
Write_512_Loop:                 ; 11 accès au bus par tour, au moins
    LDA     ,X+
    STA     SD_DATA
    DECW
    BNE     Write_512_Loop
    JSR     Spi_FF              ; CRC
    JSR     Spi_FF
    LDB     #8                  ; réponse de données : premier octet <> $FF
WB_Rep:
    JSR     Spi_Recoit
    CMPA    #$FF
    BNE     WB_RepLue
    DECB
    BNE     WB_Rep
    LDA     #$E3                ; rien : CMD24 refusé
    JMP     SD_Fin
WB_RepLue:
    ANDA    #%00011111
    CMPA    #%00000101          ; données acceptées
    BEQ     WB_Occupee
    LDA     #$E4
    JMP     SD_Fin
WB_Occupee:
    LDY     #40000              ; ~0,8 s (la norme : 250 ms, 500 en SDXC)
Wait_Busy_Loop:
    JSR     Spi_Recoit
    TSTA
    BNE     Write_Success
    LEAY    -1,Y
    BNE     Wait_Busy_Loop
    LDA     #$E5
    JMP     SD_Fin
Write_Success:
    CLRA
    JMP     SD_Fin

    section .code

CMD0_Packet:
    FCB     $40,$00,$00,$00,$00,$95
CMD8_Packet:
    FCB     $48,$00,$00,$01,$AA,$87
CMD55_Packet:
    FCB     $77,$00,$00,$00,$00,$65
ACMD41_Packet:
    FCB     $69,$40,$00,$00,$00,$77  ; $40 : la carte peut être SDHC/SDXC

    end
