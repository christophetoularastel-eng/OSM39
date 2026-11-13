; ===================================================================
; CLOURIS.ASM - Lecture de la Clouris (souris tactile, port A de l'AY)
; ===================================================================
; Six clous et une plaque de paume à la masse ; chaque clou attaque une
; porte d'un 74HC14 dont la sortie va sur le port A de l'AY (J602 de la
; carte OSM39_mono, J104 de SD-KBD-SON, même brochage). Câblage :
; cmd/cloutest.asm.
; CLOU_INVERSE = 1 : carte Clouris à transistors PNP (S9015 + 74HC14, KiCad
; clouris/) : doigt posé = bit à 0, repos et Clouris absente = $FF.
; CLOU_INVERSE = 0 : premier montage (clou -> 74HC14) : doigt = bit à 1.
; Code : à inclure APRÈS le point d'entrée.
;
; Clou_Lit : une fois par trame. Rend A = événements (Z = 1 si aucun) :
;   bits 0-3 (CLOU_HAUT...) : un pas dans cette direction (tout de suite
;            à l'appui, puis après CLOU_DELAI trames toutes les CLOU_PAS)
;   bit 4 CLOU_CENTRE, bit 5 CLOU_CLIC : l'appui vient de commencer
; Un contact compte s'il est vu deux trames de suite (les entrées à
; 9 Mohm captent le secteur). Rien de branché : port A tout à 1
; (tirages internes de l'AY) = aucun contact. Détruit B.
; ===================================================================
CLOU_HAUT       equ $01
CLOU_DROITE     equ $02
CLOU_BAS        equ $04
CLOU_GAUCHE     equ $08
CLOU_CENTRE     equ $10
CLOU_CLIC       equ $20
CLOU_DELAI      equ 12              ; trames avant la répétition
CLOU_PAS        equ 3               ; trames entre deux pas répétés
    IFNDEF  CLOU_INVERSE
CLOU_INVERSE    equ 1               ; 1 : carte à transistors PNP (doigt = 0)
    ENDC

Clou_Lit:
    PSHS    CC
    ORCC    #%00010000          ; l'IRQ du son choisit d'autres registres
    LDA     #14
    STA     AY_ADR
    LDA     AY_ADR
    PULS    CC
    IFNE    CLOU_INVERSE
    COMA                        ; doigt posé = 0 sur le port
    ANDA    #%00111111          ; absente ($FF) : aucun contact
    ELSE
    ANDA    #%00111111
    CMPA    #%00111111
    BNE     CLL_Lu
    CLRA                        ; pas de Clouris
    ENDC
CLL_Lu:
    TFR     A,B
    ANDB    ClouBrut            ; B = vu deux trames de suite
    STA     ClouBrut
    LDA     ClouTenu
    STB     ClouTenu
    COMA
    PSHS    A
    ANDB    ,S+                 ; B = appuis nouveaux
    LDA     ClouTenu
    ANDA    #%00001111          ; directions tenues
    BEQ     CLL_Fin
    BITB    #%00001111
    BEQ     CLL_Tient
    PSHS    A                   ; une direction de plus : un pas tout de suite
    LDA     #CLOU_DELAI
    BRA     CLL_Arme
CLL_Tient:
    DEC     ClouRep
    BNE     CLL_Rien
    PSHS    A
    LDA     #CLOU_PAS
CLL_Arme:
    STA     ClouRep
    PULS    A
    BRA     CLL_Fin
CLL_Rien:
    CLRA
CLL_Fin:
    ANDB    #CLOU_CENTRE+CLOU_CLIC
    PSHS    B
    ORA     ,S+
    RTS

ClouBrut        FCB 0               ; lecture précédente
ClouTenu        FCB 0               ; contacts confirmés
ClouRep         FCB 0               ; trames avant le prochain pas
