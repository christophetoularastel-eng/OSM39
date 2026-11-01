; ===================================================================
; essai_leds.asm - Envoi d'octets au clavier PS/2 par l'ACIA $A180
; ===================================================================
; Module d'essai pour TELE (page 1, $1000). Appel : A = premier octet,
; B = second octet (0 : pas de second). Pour chacun : RIE coupé, l'octet
; dans TDR, RTS bas (CLOCK tenue à 0 par D1 : le 6850 sort son start),
; ~200 µs, RTS haut (le clavier prend la main et cadence les 11 bits),
; puis ~40 ms d'écoute : chaque octet reçu est noté (SR, RDR) dans Journal.
; Rend B = nombre d'octets notés. IRQ masquées pendant tout l'essai.
; ===================================================================
    include "/home/christophe/Documents/6809/OSM39V3/bios/hardware.inc"

CR_SANS_RIE     equ $5C         ; RIE = 0, RTS haut, 8 bits parité impaire, /1
CR_RTS_BAS      equ $1C         ; RIE = 0, RTS bas : CLOCK tenue à 0
CR_NORMAL       equ $DC         ; comme le BIOS : RIE = 1, RTS haut

    section .code

Essai:
    STA     Octet1
    STB     Octet2
    CLR     NJ
    PSHS    CC
    ORCC    #%01010000
    LDA     #CR_SANS_RIE
    STA     CR_key
    BSR     Vide
    LDA     Octet1
    BSR     Envoie
    LDA     Octet2
    BEQ     Fin
    BSR     Envoie
Fin:
    BSR     Vide_Note
    LDA     #CR_NORMAL
    STA     CR_key
    PULS    CC
    LDB     NJ
    RTS

; A = octet à envoyer ; puis écoute
Envoie:
    PSHS    A
    LDA     #$EE                ; repère dans le journal : début d'un envoi
    LDB     ,S
    BSR     Note
E_Tdre:
    LDA     SR_key
    BITA    #$02
    BEQ     E_Tdre
    PULS    A
    STA     TDR_key
    LDA     #CR_RTS_BAS
    STA     CR_key
    LDX     #60                 ; ~200 µs (au moins 100 µs demandées)
E_Att:
    LEAX    -1,X
    BNE     E_Att
    LDA     SR_key              ; état juste avant de relâcher CLOCK
    LDB     #$01
    BSR     Note
    LDA     #CR_SANS_RIE
    STA     CR_key
Ecoute:
    LDX     #12000              ; ~40 ms
Ec_Boucle:
    LDA     SR_key
    BITA    #$01
    BEQ     Ec_Rien
    LDB     RDR_key
    BSR     Note
Ec_Rien:
    LEAX    -1,X
    BNE     Ec_Boucle
    RTS

; vide le récepteur sans noter
Vide:
    LDA     SR_key
    BITA    #$01
    BEQ     V_Fin
    LDA     RDR_key
    BRA     Vide
V_Fin:
    RTS

; vide le récepteur en notant
Vide_Note:
    BRA     Ecoute

; A = SR, B = octet : une ligne du journal (32 au plus)
Note:
    PSHS    X
    LDX     #Journal
    PSHS    B
    LDB     NJ
    CMPB    #32
    BHS     N_Plein
    LSLB
    ABX
    PULS    B
    STA     ,X
    STB     1,X
    INC     NJ
    PULS    X,PC
N_Plein:
    PULS    B
    PULS    X,PC

Octet1  rmb 1
Octet2  rmb 1
NJ      rmb 1
Journal rmb 64
