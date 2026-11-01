; ===================================================================
; SDTEST.ASM — Essai de la carte SD sur le SPI matériel (SD-KBD-SON)
; Usage: SDTEST
; Charge: page 1, $0000
;
; Le système tourne sur la carte SD habituelle (SPI logiciel, port B du
; PIA). Ce programme parle à la SECONDE carte, celle du support de la
; carte SD-KBD-SON, par ses deux registres :
;   SD_CTRL ($A140, écriture seule) : bit 0 = /CS (1 : carte libre),
;     bit 1 = vitesse (0 : E/16, ~115 kHz ; 1 : E, 1,8432 MHz)
;   SD_DATA ($A148) : écrire envoie l'octet ; lire rend l'octet reçu au
;     transfert PRÉCÉDENT et lance un transfert qui RENVOIE cet octet à la
;     carte (mesuré le 30 oct. 2026 : le 165 se charge aussi en lecture).
;     Sans effet quand la carte parle ; mais après le R1 de CMD24, un 00
;     renvoyé est pris pour le début du bloc : CMD24 part donc « à
;     l'aveugle » (Ecrit_Secteur), sans aucune lecture avant le jeton.
; Pas de bit « occupé » : il faut au moins 9 cycles de bus entre deux
; accès en rapide, 150 en lent (tools/carte_sd_kbd_son/simule.py). Les
; boucles sont écrites pour ça ; test/verifie_sdtest.py le vérifie en
; comptant les accès au bus.
;
; Étapes : init en lent (CMD0, CMD8, ACMD41, CMD58), passage en rapide,
; identité (CID, CSD : capacité), secteur 0, 200 lectures du secteur 0
; comparées à la première, puis, si on répond O, écriture d'un motif au
; secteur LBA_ESSAI, relecture, et remise du contenu d'origine.
; Chaque réponse est affichée en hexa : c'est un outil de mise au point.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

LENT_CS_HAUT    equ $01         ; SD_CTRL : E/16, carte libre
LENT_CS_BAS     equ $00         ; E/16, carte sélectionnée
RAPIDE_CS_BAS   equ $02         ; E, carte sélectionnée
ATT_LENT        equ 60          ; tours de DECB/BNE après un octet en lent
NB_LECTURES     equ 200
LBA_ESSAI_H     equ $0010       ; secteur d'essai $00100000 (512 Mo)
LBA_ESSAI_L     equ $0000
TAMPON1         equ $4000       ; 512 octets chacun, dans notre page
TAMPON2         equ $4200
TAMPON3         equ $4400

    section .code

Start:
    LDX     #MsgTitre
    JSR     Aff_Ligne
    JSR     Essai
    LDA     #LENT_CS_HAUT       ; dans tous les cas : carte libérée
    JSR     Spi_Ctrl
    RTS

; -------------------------------------------------------------------
; L'essai complet. Rend la main au premier échec (message affiché).
; -------------------------------------------------------------------
Essai:
    ; --- 80 coups d'horloge /CS haut, puis /CS bas ---
    LDA     #LENT_CS_HAUT
    JSR     Spi_Ctrl
    LDB     #10
ES_Hor:
    LDA     #$FF
    JSR     Spi_Envoie
    DECB
    BNE     ES_Hor
    LDA     #LENT_CS_BAS
    JSR     Spi_Ctrl
    ; --- CMD0 : R1 = $01 (repos) ---
    JSR     Arg_Zero
    LDA     #0
    LDB     #$95
    JSR     Sd_Cmd
    LDX     #MsgCmd0
    JSR     Aff_R1
    LBCS    Echec
    CMPA    #$01
    LBNE    Echec
    ; --- CMD8 $1AA : R1 = $01 puis 00 00 01 AA (carte SD v2) ---
    LDD     #$0000
    STD     Arg
    LDD     #$01AA
    STD     Arg+2
    LDA     #8
    LDB     #$87
    JSR     Sd_Cmd
    LDX     #MsgCmd8
    JSR     Aff_R1
    LBCS    Echec
    CMPA    #$01
    LBNE    Echec
    JSR     Lit4
    JSR     Aff_Quatre
    LDA     Quatre+3
    CMPA    #$AA
    LBNE    Echec
    ; --- ACMD41 (HCS) jusqu'à R1 = 0 ---
    LDD     #0
    STD     Essais
ES_41:
    LDD     Essais
    ADDD    #1
    STD     Essais
    CMPD    #2000
    BHI     ES_41_Ko
    JSR     Arg_Zero
    LDA     #55
    LDB     #$65
    JSR     Sd_Cmd
    BCS     ES_41_Ko
    LDD     #$4000
    STD     Arg
    LDA     #41
    LDB     #$77
    JSR     Sd_Cmd
    BCS     ES_41_Ko
    TSTA
    BNE     ES_41
    LDX     #MsgAcmd41
    JSR     Aff
    LDD     Essais
    JSR     Aff_Dec
    LDX     #MsgEssais
    JSR     Aff_Ligne
    BRA     ES_58
ES_41_Ko:
    LDX     #MsgAcmd41Ko
    JSR     Aff_Ligne
    LBRA    Echec
    ; --- CMD58 : OCR, bit 30 = CCS (adressage en secteurs) ---
ES_58:
    JSR     Arg_Zero
    LDA     #58
    LDB     #$FD
    JSR     Sd_Cmd
    LDX     #MsgCmd58
    JSR     Aff_R1
    LBCS    Echec
    TSTA
    LBNE    Echec
    JSR     Lit4
    JSR     Aff_Quatre
    LDA     Quatre
    BITA    #$40
    BNE     ES_Hc
    LDX     #MsgSdsc
    JSR     Aff_Ligne
    LBRA    Echec
ES_Hc:
    LDX     #MsgSdhc
    JSR     Aff_Ligne
    ; --- vitesse rapide ---
    LDA     #RAPIDE_CS_BAS
    JSR     Spi_Ctrl
    LDX     #MsgRapide
    JSR     Aff_Ligne
    ; --- CID (CMD10) : fabricant, OEM, nom ---
    JSR     Arg_Zero
    LDA     #10
    LDX     #TAMPON1
    LDW     #16
    JSR     Sd_Bloc
    LDX     #MsgCid
    LBCS    Echec_Code
    JSR     Aff
    LDA     TAMPON1             ; fabricant
    JSR     [table_function_ram+sys_PrintHexChar]
    LDX     #MsgOem
    JSR     Aff
    LDX     #TAMPON1+1          ; OEM : 2 caractères
    LDB     #2
    JSR     Aff_N
    LDX     #MsgNom
    JSR     Aff
    LDX     #TAMPON1+3          ; nom : 5 caractères
    LDB     #5
    JSR     Aff_N
    JSR     [table_function_ram+sys_PrintCRLF]
    ; --- CSD (CMD9) : capacité, si CSD v2 ---
    JSR     Arg_Zero
    LDA     #9
    LDX     #TAMPON1
    LDW     #16
    JSR     Sd_Bloc
    LDX     #MsgCsd
    LBCS    Echec_Code
    JSR     Aff
    LDA     TAMPON1
    ANDA    #$C0
    CMPA    #$40
    BNE     ES_CsdV1
    ; C_SIZE (22 bits) = octets 7 (6 bits), 8, 9 ; Mo = (C_SIZE + 1) / 2
    LDD     TAMPON1+8
    ADDD    #1
    STD     Taille
    LDA     TAMPON1+7
    ANDA    #$3F
    ADCA    #0
    LSRA                        ; décalage de 24 bits d'un cran à droite
    ROR     Taille
    ROR     Taille+1
    TSTA
    BNE     ES_Grosse
    LDD     Taille
    JSR     Aff_Dec
    LDX     #MsgMo
    JSR     Aff_Ligne
    BRA     ES_Sect0
ES_Grosse:
    LDX     #MsgGrosse
    JSR     Aff_Ligne
    BRA     ES_Sect0
ES_CsdV1:
    LDX     #MsgCsdV1
    JSR     Aff_Ligne
    ; --- secteur 0 : 16 premiers octets, signature OSMF en 508 ---
ES_Sect0:
    JSR     Arg_Zero
    LDX     #TAMPON1
    JSR     Lit_Secteur
    LDX     #MsgSect0
    LBCS    Echec_Code
    JSR     Aff
    LDX     #TAMPON1
    LDB     #16
ES_Hex:
    LDA     ,X+
    JSR     [table_function_ram+sys_PrintHexChar]
    LDA     #' '
    JSR     [table_function_ram+sys_PrintChar]
    DECB
    BNE     ES_Hex
    JSR     [table_function_ram+sys_PrintCRLF]
    LDX     #MsgSign
    JSR     Aff
    LDX     #TAMPON1+508
    LDB     #4
    JSR     Aff_N
    LDD     TAMPON1+508
    CMPD    #$4F53              ; "OS"
    BNE     ES_PasOsm
    LDD     TAMPON1+510
    CMPD    #$4D46              ; "MF"
    BNE     ES_PasOsm
    LDX     #MsgOsmfs
    BRA     ES_SignAff
ES_PasOsm:
    LDX     #MsgVierge
ES_SignAff:
    JSR     Aff_Ligne
    ; --- fiabilité et débit : NB_LECTURES lectures du secteur 0 ---
    LDX     #MsgFiab
    JSR     Aff_Ligne
    LDD     #0
    STD     Erreurs
    STD     Compte
    LDD     vsync_tick
    STD     Trame0
ES_Fiab:
    JSR     Arg_Zero
    LDX     #TAMPON2
    JSR     Lit_Secteur
    BCS     ES_FiabErr
    LDX     #TAMPON1
    LDY     #TAMPON2
    JSR     Compare
    BEQ     ES_FiabSuiv
ES_FiabErr:
    LDD     Erreurs
    ADDD    #1
    STD     Erreurs
ES_FiabSuiv:
    LDD     Compte
    ADDD    #1
    STD     Compte
    CMPD    #NB_LECTURES
    BLO     ES_Fiab
    LDD     vsync_tick
    SUBD    Trame0
    STD     Trames
    LDD     #NB_LECTURES
    JSR     Aff_Dec
    LDX     #MsgLectures
    JSR     Aff
    LDD     Erreurs
    JSR     Aff_Dec
    LDX     #MsgErreurs
    JSR     Aff
    LDD     Trames
    JSR     Aff_Dec
    LDX     #MsgTrames
    JSR     Aff
    ; Ko/s = 100 Ko x 60 trames / Trames
    LDD     Trames
    BEQ     ES_SansDebit
    LDY     #0
    LDD     #6000
ES_Div:
    CMPD    Trames
    BLO     ES_DivFin
    SUBD    Trames
    LEAY    1,Y
    BRA     ES_Div
ES_DivFin:
    LDX     #MsgSoit
    JSR     Aff
    TFR     Y,D
    JSR     Aff_Dec
    LDX     #MsgKos
    JSR     Aff_Ligne
    BRA     ES_Ecrire
ES_SansDebit:
    JSR     [table_function_ram+sys_PrintCRLF]
    ; --- écriture (sur demande) ---
ES_Ecrire:
    LDX     #MsgDemande
    JSR     Aff
ES_Touche:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     ES_Touche
    ANDA    #$DF
    CMPA    #'O'
    BEQ     ES_Oui
    LDX     #MsgNon
    JSR     Aff_Ligne
    LBRA    Fin_Ok
ES_Oui:
    LDX     #MsgOui
    JSR     Aff_Ligne
    JSR     Arg_Essai           ; 1. le contenu d'origine
    LDX     #TAMPON3
    JSR     Lit_Secteur
    LDX     #MsgLitOrig
    LBCS    Echec_Code
    LDX     #TAMPON2            ; 2. le motif : 3 + 7 i
    LDB     #3
    LDW     #512
ES_Motif:
    STB     ,X+
    ADDB    #7
    DECW
    BNE     ES_Motif
    JSR     Arg_Essai
    LDX     #TAMPON2
    JSR     Ecrit_Secteur
    JSR     Aff_Ecrit
    LDX     #MsgEcrit
    LBCS    Echec_Ecrit
    JSR     Arg_Essai           ; 3. relu, comparé
    LDX     #TAMPON1
    JSR     Lit_Secteur
    LDX     #MsgRelu
    LBCS    Echec_Code
    LDX     #TAMPON1
    LDY     #TAMPON2
    JSR     Compare
    BEQ     ES_Pareil
    LDX     #MsgDiff
    JSR     Aff_Ligne
    BRA     ES_Remet
ES_Pareil:
    LDX     #MsgPareil
    JSR     Aff_Ligne
ES_Remet:
    JSR     Arg_Essai           ; 4. l'origine remise
    LDX     #TAMPON3
    JSR     Ecrit_Secteur
    JSR     Aff_Ecrit
    LDX     #MsgRemis
    LBCS    Echec_Ecrit
    JSR     Aff_Ligne
Fin_Ok:
    LDX     #MsgFini
    JSR     Aff_Ligne
    RTS

; X = étape, A = code : « ECHEC : étape (code $xx) »
Echec_Code:
    PSHS    A
    PSHS    X
    LDX     #MsgEchec
    JSR     Aff
    PULS    X
    JSR     Aff
    LDX     #MsgCode
    JSR     Aff
    PULS    A
    JSR     [table_function_ram+sys_PrintHexChar]
    LDA     #')'
    JSR     [table_function_ram+sys_PrintChar]
    JSR     [table_function_ram+sys_PrintCRLF]
    RTS
; Échec d'écriture : le message, puis l'état de la carte (CMD13 : R2).
Echec_Ecrit:
    JSR     Echec_Code
    JSR     Arg_Zero
    LDA     #13
    LDB     #$01
    JSR     Sd_Cmd
    LDX     #MsgCmd13
    JSR     Aff_R1
    BCS     Echec
    LDX     #MsgSuite
    JSR     Aff
    JSR     Spi_Recoit
    JSR     [table_function_ram+sys_PrintHexChar]
    JSR     [table_function_ram+sys_PrintCRLF]
Echec:
    LDX     #MsgArret
    JSR     Aff_Ligne
    RTS

; -------------------------------------------------------------------
; Registres SPI
; -------------------------------------------------------------------
; A -> SD_CTRL (et sa copie : le registre ne se relit pas)
Spi_Ctrl:
    STA     Ctrl
    STA     SD_CTRL
    RTS

; A = octet envoyé. Préserve A et B.
Spi_Envoie:
    STA     SD_DATA
    BRA     Spi_Attente

; A = octet reçu au transfert précédent (et un $FF part). Préserve B.
Spi_Recoit:
    LDA     SD_DATA

; Laisse finir le transfert lancé : rien à faire en rapide (l'appel et
; le retour durent plus de 9 cycles), ATT_LENT tours en lent.
Spi_Attente:
    PSHS    B
    LDB     Ctrl
    BITB    #$02
    BNE     SA_Fin
    LDB     #ATT_LENT
SA_Tour:
    DECB
    BNE     SA_Tour
SA_Fin:
    PULS    B,PC

; -------------------------------------------------------------------
; Commandes SD
; -------------------------------------------------------------------
Arg_Zero:
    PSHS    D
    LDD     #0
    STD     Arg
    STD     Arg+2
    PULS    D,PC

Arg_Essai:
    PSHS    D
    LDD     #LBA_ESSAI_H
    STD     Arg
    LDD     #LBA_ESSAI_L
    STD     Arg+2
    PULS    D,PC

; A = n° de commande, B = CRC, Arg = argument (4 octets). Rend A = R1 ;
; C = 1 si aucune réponse en 10 octets.
Sd_Cmd:
    PSHS    B
    PSHS    A
    LDA     #$FF                ; un octet de garde
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
    BPL     SC_Ok               ; bit 7 = 0 : c'est R1
    DECB
    BNE     SC_R1
    ORCC    #1
    RTS
SC_Ok:
    ANDCC   #$FE
    RTS

; Lit4 : les 4 octets qui suivent R1 (R7, OCR) dans Quatre.
Lit4:
    LDX     #Quatre
    LDB     #4
L4_Oct:
    JSR     Spi_Recoit
    STA     ,X+
    DECB
    BNE     L4_Oct
    RTS

; A = commande (9, 10 ou 17), Arg, X = tampon, W = longueur (rapide
; seulement). R1, jeton $FE, données, CRC. C = 1 en échec, A = code :
; R1 si non nul, le jeton d'erreur reçu, ou $FF (pas de jeton).
Sd_Bloc:
    PSHS    X
    LDB     #$01                ; CRC non vérifié par la carte
    JSR     Sd_Cmd
    BCS     SB_Ko
    TSTA
    BNE     SB_Ko
    LDX     #4000               ; jeton : 4000 octets au plus
SB_Jeton:
    JSR     Spi_Recoit
    CMPA    #$FE
    BEQ     SB_Donnees
    CMPA    #$FF
    BNE     SB_Ko               ; jeton d'erreur
    LEAX    -1,X
    BNE     SB_Jeton
    BRA     SB_Ko
SB_Donnees:
    PULS    X
SB_Oct:                         ; 11 accès au bus par tour, au moins
    LDA     SD_DATA
    STA     ,X+
    DECW
    BNE     SB_Oct
    JSR     Spi_Recoit          ; CRC (2 octets)
    JSR     Spi_Recoit
    ANDCC   #$FE
    RTS
SB_Ko:
    PULS    X
    ORCC    #1
    RTS

; Lit le secteur Arg dans X (512 octets). C = 1 en échec, A = code.
Lit_Secteur:
    LDA     #17
    LDW     #512
    BRA     Sd_Bloc

; Écrit les 512 octets de X au secteur Arg. CMD24 puis 8 x $FF écrits
; (R1 passe pendant ces octets, sans être lu : voir l'en-tête), jeton,
; données, CRC. Un R1 d'erreur se voit à l'absence de réponse de données.
; C = 1 en échec, A = code :
; la réponse de données (attendu xxx00101), $FF (pas de réponse) ou
; $00 (toujours occupée après ~10 s). Pour le diagnostic : Trace = les 8
; octets reçus après le CRC, Occupe = trames passées à attendre la fin
; d'occupation (après la trace).
Ecrit_Secteur:
    LDA     #$FF                ; garde, puis CMD24 octet par octet
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
    LDA     #$FF                ; R1 (NCR : 8 octets au plus), non lu
    LDB     #8
EC_Ncr:
    JSR     Spi_Envoie
    DECB
    BNE     EC_Ncr
    LDA     #$FE
    JSR     Spi_Envoie
    LDW     #512
EC_Oct:                         ; 11 accès au bus par tour, au moins
    LDA     ,X+
    STA     SD_DATA
    DECW
    BNE     EC_Oct
    LDA     #$FF                ; CRC
    JSR     Spi_Envoie
    JSR     Spi_Envoie
    LDD     #0
    STD     Occupe
    LDX     #Trace              ; les 8 octets suivants, tels quels
    LDB     #8
EC_Trace:
    JSR     Spi_Recoit
    STA     ,X+
    DECB
    BNE     EC_Trace
    LDX     #Trace              ; la réponse : premier octet <> $FF
    LDB     #8
EC_Rep:
    LDA     ,X+
    CMPA    #$FF
    BNE     EC_RepLue
    DECB
    BNE     EC_Rep
    ORCC    #1                  ; A = $FF : pas de réponse
    RTS
EC_RepLue:
    TFR     A,B
    ANDB    #$1F
    CMPB    #$05
    BNE     EC_Err
    CMPX    #Trace+8            ; réponse en dernier : l'occupation suit
    BEQ     EC_Attend
    LDA     Trace+7             ; sinon finie si le dernier octet <> 0
    BNE     EC_Fin
EC_Attend:
    LDD     vsync_tick
    STD     Trame0
    LDY     #8                  ; 8 x 65536 octets au plus (~10 s)
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
    CLRA                        ; A = 0 : toujours occupée
    ORCC    #1
    RTS
EC_Duree:
    BSR     EC_Mesure
EC_Fin:
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

; Compare 512 octets de X et Y : Z = 1 si pareils.
Compare:
    LDW     #512
CP_Oct:
    LDA     ,X+
    CMPA    ,Y+
    BNE     CP_Fin
    DECW
    BNE     CP_Oct
CP_Fin:
    RTS

; -------------------------------------------------------------------
; Affichage
; -------------------------------------------------------------------
Aff:
    JMP     [table_function_ram+sys_PrintString]

Aff_Ligne:
    JSR     [table_function_ram+sys_PrintString]
    JMP     [table_function_ram+sys_PrintCRLF]

; X = libellé, A = R1, C = 1 : pas de réponse. Préserve A et C.
Aff_R1:
    PSHS    CC,A
    JSR     Aff
    LDA     1,S
    LDB     ,S
    BITB    #1
    BNE     AR_Rien
    JSR     [table_function_ram+sys_PrintHexChar]
    BRA     AR_Fin
AR_Rien:
    LDX     #MsgRien
    JSR     Aff
AR_Fin:
    JSR     [table_function_ram+sys_PrintCRLF]
    PULS    CC,A,PC

; Après une écriture : « apres le CRC : xx x 8, occupee N trames ».
; Préserve A et CC.
Aff_Ecrit:
    PSHS    CC,A
    LDX     #MsgApres
    JSR     Aff
    LDX     #Trace
    LDB     #8
AE_Oct:
    LDA     ,X+
    JSR     [table_function_ram+sys_PrintHexChar]
    LDA     #' '
    JSR     [table_function_ram+sys_PrintChar]
    DECB
    BNE     AE_Oct
    LDX     #MsgOccupee
    JSR     Aff
    LDD     Occupe
    JSR     Aff_Dec
    LDX     #MsgTrames
    JSR     Aff_Ligne
    PULS    CC,A,PC

Aff_Quatre:
    LDX     #MsgSuite
    JSR     Aff
    LDX     #Quatre
    LDB     #4
AQ_Oct:
    LDA     ,X+
    JSR     [table_function_ram+sys_PrintHexChar]
    DECB
    BNE     AQ_Oct
    JMP     [table_function_ram+sys_PrintCRLF]

; X = texte, B = longueur : caractères imprimables, '.' sinon.
Aff_N:
    LDA     ,X+
    CMPA    #$20
    BLO     AN_Point
    CMPA    #$7E
    BLS     AN_Car
AN_Point:
    LDA     #'.'
AN_Car:
    JSR     [table_function_ram+sys_PrintChar]
    DECB
    BNE     Aff_N
    RTS

; D = valeur, en décimal sans zéros de tête.
Aff_Dec:
    PSHS    D,X
    LDX     #Puiss10
    CLR     Tete
AD_Chiffre:
    CLR     Chiffre
AD_Sous:
    CMPD    ,X
    BLO     AD_Aff
    SUBD    ,X
    INC     Chiffre
    BRA     AD_Sous
AD_Aff:
    PSHS    D
    LDA     Chiffre
    BNE     AD_Ecrit
    TST     Tete
    BNE     AD_Ecrit
    CMPX    #Puiss10+8          ; les unités : toujours
    BNE     AD_Saute
AD_Ecrit:
    INC     Tete                ; <> 0 dès le premier chiffre écrit
    ADDA    #'0'
    JSR     [table_function_ram+sys_PrintChar]
AD_Saute:
    PULS    D
    LEAX    2,X
    CMPX    #Puiss10+10
    BNE     AD_Chiffre
    PULS    D,X,PC

Puiss10:        FDB 10000,1000,100,10,1

; --- Textes (sans accents : police page 0) ---
MsgTitre:       FCN "SDTEST - carte SD sur le SPI materiel (SD-KBD-SON)"
MsgCmd0:        FCN "CMD0   R1="
MsgCmd8:        FCN "CMD8   R1="
MsgCmd58:       FCN "CMD58  R1="
MsgRien:        FCN "rien (pas de carte ?)"
MsgSuite:       FCN "       suite "
MsgAcmd41:      FCN "ACMD41 prete apres "
MsgEssais:      FCN " essai(s)"
MsgAcmd41Ko:    FCN "ACMD41 : la carte ne devient pas prete"
MsgSdsc:        FCN "Carte SDSC (2 Go ou moins) : non geree"
MsgSdhc:        FCN "Carte SDHC/SDXC (adresses en secteurs)"
MsgRapide:      FCN "Passage en rapide (1,8 MHz)"
MsgCid:         FCN "CID    fabricant $"
MsgOem:         FCN "  OEM "
MsgNom:         FCN "  nom "
MsgCsd:         FCN "CSD    capacite "
MsgMo:          FCN " Mo"
MsgGrosse:      FCN "64 Go ou plus"
MsgCsdV1:       FCN "(CSD v1)"
MsgSect0:       FCN "Secteur 0 : "
MsgSign:        FCN "Octets 508-511 : "
MsgOsmfs:       FCN "  (carte OSMFS)"
MsgVierge:      FCN "  (pas OSMFS : carte vierge ?)"
MsgFiab:        FCN "Lectures repetees du secteur 0..."
MsgLectures:    FCN " lectures, "
MsgErreurs:     FCN " erreur(s), "
MsgTrames:      FCN " trames"
MsgSoit:        FCN ", soit "
MsgKos:         FCN " Ko/s"
MsgDemande:     FCN "Ecrire au secteur $00100000 (remis ensuite) ? (O/N) "
MsgOui:         FCN "O"
MsgNon:         FCN "N"
MsgLitOrig:     FCN "lecture de l'origine"
MsgEcrit:       FCN "ecriture du motif"
MsgRelu:        FCN "relecture"
MsgPareil:      FCN "Motif ecrit et relu : identique"
MsgDiff:        FCN "Motif relu DIFFERENT"
MsgRemis:       FCN "Contenu d'origine remis"
MsgFini:        FCN "Essai termine."
MsgEchec:       FCN "ECHEC : "
MsgCode:        FCN " (code $"
MsgArret:       FCN "Essai arrete."
MsgCmd13:       FCN "CMD13  R1="
MsgApres:       FCN "  apres le CRC : "
MsgOccupee:     FCN " occupee "

; --- Variables ---
Ctrl            rmb 1           ; copie de SD_CTRL
Arg             rmb 4           ; argument des commandes (gros-boutiste)
Quatre          rmb 4
Essais          rmb 2
Taille          rmb 2
Erreurs         rmb 2
Compte          rmb 2
Trame0          rmb 2
Trames          rmb 2
Occupe          rmb 2
Trace           rmb 8
Tete            rmb 1
Chiffre         rmb 1
