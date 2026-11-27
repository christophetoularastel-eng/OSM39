; ===================================================================
; JOY.ASM - Le joystick sur le port A de l'AY, étalonné par JOYCAL
; ===================================================================
; Quatre micro-rupteurs (haut, droite, bas, gauche) et un bouton, chacun
; entre un bit du port A de l'AY (J602 de la carte OSM39_mono) et la
; masse ; les tirages internes de l'AY tiennent les autres bits à 1 :
; appuyé = bit à 0, repos (et rien de branché) = $FF. Le joystick peut
; être monté dans n'importe quel sens et câblé dans n'importe quel ordre :
; JOYCAL demande chaque direction et écrit /BIN/JOYSTICK.CFG (JOY_TAILLE
; octets : "JOY", la version 1, puis les masques du port A pour haut,
; droite, bas, gauche, bouton). Sans ce fichier (ou s'il est faux) : le
; brochage de la Clouris (IOA0 haut, IOA1 droite, IOA2 bas, IOA3 gauche,
; IOA5 bouton).
; Code : à inclure APRÈS le point d'entrée.
;
; Joy_Init : charge l'étalonnage -> A = 1 s'il vient du fichier, 0 sinon.
;            Détruit tous les registres.
; Joy_Brut : A = les bits du port A appuyés (1 = appuyé), 0 sans AY (Z).
;            Détruit B.
; Joy_Lit  : A = JOY_HAUT... (1 = appuyé, les diagonales donnent deux
;            bits), Z = 1 si rien. Aucune temporisation : à lire à chaque
;            trame (les jeux). Détruit B, X.
; Joy_Evts : une fois par trame (un pointeur, un menu : OSM-VISION) ->
;            A = événements, Z = 1 si aucun : bits 0-3 un pas dans cette
;            direction (à l'appui, puis après JOY_DELAI trames toutes les
;            JOY_PAS), JOY_BOUTON l'appui vient de commencer. Un appui
;            compte s'il est vu deux trames de suite (le rythme de la
;            Clouris). Détruit B, X.
; Sans AY (puce retirée ou morte), le port A lirait le bus vide : des bits
; à 0, des appuis permanents. Au premier appel, Joy_Sonde écrit $05 puis
; $0A dans R1 (période haute de la voie A, 4 bits) et les relit : une vraie
; puce rend les deux, le bus vide jamais ; R1 retrouve sa valeur. Pas
; d'AY : rien n'est jamais appuyé (comme lib/clouris.asm).
; ===================================================================
JOY_HAUT        equ $01
JOY_DROITE      equ $02
JOY_BAS         equ $04
JOY_GAUCHE      equ $08
JOY_BOUTON      equ $10
JOY_N           equ 5               ; les masques : haut, droite, bas, gauche, bouton
JOY_TAILLE      equ 9               ; "JOY", 1, 5 masques
JOY_DELAI       equ 12              ; Joy_Evts : trames avant la répétition
JOY_PAS         equ 3               ; trames entre deux pas répétés

Joy_Init:
    LDX     #JoyDefaut              ; d'abord le brochage de la Clouris
    LDY     #JoyMasq
    LDB     #JOY_N
JI_Def:
    LDA     ,X+
    STA     ,Y+
    DECB
    BNE     JI_Def
    CLR     JoyCfg
    LDX     #JoyNomCfg
    LDY     #JoyNom
    JSR     [table_function_ram+sys_Format_Filename_83]
    LDX     #JoyNom                 ; la taille d'abord (rien d'autre n'entre)
    JSR     [table_function_ram+sys_FS_FindEntry]
    BCS     JI_Fin
    CMPU    #JOY_TAILLE
    BNE     JI_Fin
    LDX     #JoyNom
    LDA     >current_page
    LDY     #JoyFic
    JSR     [table_function_ram+sys_FS_LoadFile]
    BCS     JI_Fin
    LDX     #JoyFic                 ; "JOY", version 1
    LDY     #JoyEntete
    LDB     #4
JI_Ent:
    LDA     ,X+
    CMPA    ,Y+
    BNE     JI_Fin
    DECB
    BNE     JI_Ent
    BSR     Joy_Valides             ; X = les 5 masques du fichier
    BCS     JI_Fin
    LDX     #JoyFic+4
    LDY     #JoyMasq
    LDB     #JOY_N
JI_Copie:
    LDA     ,X+
    STA     ,Y+
    DECB
    BNE     JI_Copie
    LDA     #1
    STA     JoyCfg
JI_Fin:
    LDA     JoyCfg
    RTS

; Joy_Valides : X = JOY_N masques -> C = 1 sauf si chacun a un seul bit
; et qu'ils sont tous différents. Préserve X.
Joy_Valides:
    PSHS    X
    CLR     JoyVu
    LDB     #JOY_N
JV_Masque:
    LDA     ,X+
    BEQ     JV_Non
    PSHS    A                       ; un seul bit : m & (m - 1) = 0
    DECA
    ANDA    ,S
    PULS    A
    BNE     JV_Non
    BITA    JoyVu                   ; pas déjà pris
    BNE     JV_Non
    ORA     JoyVu
    STA     JoyVu
    DECB
    BNE     JV_Masque
    ANDCC   #$FE
    PULS    X,PC
JV_Non:
    ORCC    #1
    PULS    X,PC

Joy_Brut:
    LDA     JoyAY                   ; 0 : pas encore sondé, 1 : AY là, $FF : absent
    BNE     JB_Sonde
    BSR     Joy_Sonde
    LDA     JoyAY
JB_Sonde:
    BPL     JB_Lire
    CLRA                            ; pas d'AY : rien d'appuyé
    RTS
JB_Lire:
    PSHS    CC
    ORCC    #%00010000              ; l'IRQ du son choisit d'autres registres
    LDA     #14
    STA     AY_ADR
    LDA     AY_ADR
    PULS    CC
    COMA                            ; appuyé = 0 sur le port
    RTS

Joy_Lit:
    BSR     Joy_Brut
    STA     JoyB
    CLRB
    LDX     #JoyMasq+JOY_N          ; du bouton au haut : B se décale à gauche
JL_Masque:
    LSLB
    LDA     ,-X
    ANDA    JoyB
    BEQ     JL_Pas
    INCB
JL_Pas:
    CMPX    #JoyMasq
    BHI     JL_Masque
    TFR     B,A
    TSTA
    RTS

Joy_Evts:
    BSR     Joy_Lit
    TFR     A,B
    ANDB    JoyPrec                 ; B = vu deux trames de suite
    STA     JoyPrec
    LDA     JoyTenu
    STB     JoyTenu
    COMA
    PSHS    A
    ANDB    ,S+                     ; B = appuis nouveaux
    LDA     JoyTenu
    ANDA    #%00001111              ; directions tenues
    BEQ     JE_Fin
    BITB    #%00001111
    BEQ     JE_Tient
    PSHS    A                       ; une direction de plus : un pas tout de suite
    LDA     #JOY_DELAI
    BRA     JE_Arme
JE_Tient:
    DEC     JoyRep
    BNE     JE_Rien
    PSHS    A
    LDA     #JOY_PAS
JE_Arme:
    STA     JoyRep
    PULS    A
    BRA     JE_Fin
JE_Rien:
    CLRA
JE_Fin:
    ANDB    #JOY_BOUTON
    PSHS    B
    ORA     ,S+
    RTS

; Joy_Sonde : JoyAY = 1 si l'AY relit $05 puis $0A dans R1, $FF sinon ;
; R1 retrouve sa valeur. IRQ masquées.
Joy_Sonde:
    PSHS    CC
    ORCC    #%00010000
    LDA     #1
    STA     AY_ADR
    LDA     AY_ADR                  ; valeur de R1, à remettre
    PSHS    A
    LDB     #$FF                    ; absent, sauf preuve du contraire
    LDA     #$05
    STA     AY_DATA
    LDA     AY_ADR
    CMPA    #$05
    BNE     JS_Fin
    LDA     #$0A
    STA     AY_DATA
    LDA     AY_ADR
    CMPA    #$0A
    BNE     JS_Fin
    LDB     #1
JS_Fin:
    PULS    A
    STA     AY_DATA                 ; R1 (toujours choisi) retrouve sa valeur
    STB     JoyAY
    PULS    CC,PC

JoyDefaut       FCB $01,$02,$04,$08,$20 ; le brochage de la Clouris
JoyEntete       FCC "JOY"
                FCB 1
JoyNomCfg       FCN "JOYSTICK.CFG"
JoyAY           FCB 0               ; 0 : à sonder, 1 : AY présent, $FF : absent
JoyCfg          FCB 0               ; 1 : l'étalonnage vient du fichier
JoyMasq         RMB JOY_N           ; haut, droite, bas, gauche, bouton
JoyPrec         FCB 0               ; Joy_Evts : la lecture précédente
JoyTenu         FCB 0               ;   les appuis confirmés
JoyRep          FCB 0               ;   trames avant le prochain pas
JoyB            RMB 1
JoyVu           RMB 1
JoyFic          RMB JOY_TAILLE
JoyNom          RMB 16
