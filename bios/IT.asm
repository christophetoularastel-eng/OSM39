        include "hardware.inc"
        include "sysfunc.inc"

        import  rvec_SWI3, rvec_SWI2,rvec_FIRQ,rvec_IRQ,rvec_SWI,rvec_NMI,rvec_TRAP
        import write_line_ptr,read_line_ptr,RAM_TOP
        import input_buffer
        ;import PrintChar
        ;import PrintString
        import trap_active
        import DiagPut
        import table_function_ram
        ;import reg_cmd
        import main
        export X_Zone_IRQ, X_Audio, UPDATE_CURSOR
        include "ext.inc"
        import  ExtV
        import Ay_Note,Ay_Silence
        import NEW_CODE
        import SCAN_CODE
        import  BITCOUNT
        import  PS2_BYTE
        import  vsync_tick,SCREEN_START_OFFSET, MUSIC_PTR, MUSIC_TIMER
        import  trap_frame, trap_info, boot_chaud, Redemarrage, Secours
        import  serie_brute, serie_tete, serie_queue, serie_buf
        import  kbd_buf, kbd_tete, kbd_queue, kbd_echap, kbd_muet
        import  Kbd_Voyants
        import  cz_actif,cz_l,cz_h,cz_haut,cz_bas,cz_op,cz_n,cz_ptr,cz_cpt
        ;import readkey2_ptr, key2_ptr, key2_buffer
        export  handler_NMI,handler_FIRQ,handler_IRQ,handler_SWI,handler_SWI2,handler_SWI3,handler_TRAP

PTM_CR1_CR3 EQU CR1  ; Registres de contrôle 1 ou 3 (selon le bit 0 de CR2)
PTM_CR2     EQU CR2  ; Registre de contrôle 2
PTM_T2_MSB  EQU TIMER2  ; Timer 2 (Son Voie 1) - MSB, LSB est à +5
PTM_T3_MSB  EQU TIMER3  ; Timer 3 (Son Voie 2) - MSB, LSB est à +7
FIN_MUSIQUE  EQU $FFFF  ; Marqueur de fin

line_ptr:        equ input_buffer
        section .code


;*******************************************************************************************
;            ici on traite l'IT VSYNC sur C1 du 68B40
;*******************************************************************************************

handler_IRQ:
        ; IRQ VSYNC (68B40, compteur T1, time-out à chaque front VSYNC).
        ; Acquittement : lecture du Status ($A081) puis du compteur T1
        ; ($A082) pour effacer le flag (IRQ niveau : sans cela elle reste
        ; collée à 0 → re-assertion immédiate après RTI → boucle infinie).
        ; Puis on incrémente vsync_tick (16 bits), lu par video_wait_vsync.
        ; NB : pas besoin de pshs : l'IRQ sauvegarde tout l'état (E=1) et
        ; RTI le restaure (A, B, X, Y, U, DP).
        lda #$5c
        sta     CR_key           ; on interdit les IT clavier (NMI)

        lda     STATUS           ; registre d'état (partagé avec CR2, en lecture)
        ldx     TIMER1           ; MSB compteur T1 : efface le flag

        ldx     vsync_tick
        leax    1,x
        stx     vsync_tick
        jsr     Kbd_Voyants     ; voyants du clavier (Verr. Maj) ; NMI muette

        ; --- SONDE TEMPORAIRE (à retirer) : '.' entre dans le handler ---
        ;lda     #'.'
        ;jsr     DiagPut

VSYNC_IRQ:
        TST     cz_actif        ; console dans une zone (Terminal) ?
        LBNE    Zone_IRQ
        ; 2. Le buffer est-il vide ?
        LDA     BUF_HEAD
        CMPA    BUF_TAIL
        LBEQ    UPDATE_CURSOR         ; Si Head == Tail, on sort tout de suite !

        ; 3. Initialisation des registres pour la course
        LDB     BUF_TAIL        ; B = Index de lecture
        LDy     VRAM_PTR        ; y = Position actuelle sur l'écran
        LDX     #8             ; x = COMPTEUR MAX : 8 caractères au plus par VSYNC

        ; V4 : caractères en $8000, couleurs en $9000 (= + VRAM_COL_OFS) ;
        ; $A120 ne porte plus que la page, posée une fois ici.
        LDA     CUR_PAGE
        STA     VRAM_CTRL

LOOP_CHAR:
        LDu     #ASCII_BUF
        clra
        leau     d,u             ; Lit l'ASCII depuis le buffer circulaire
        lda     ,u
        cmpa    #$0d
        bne not_CR
        ldy     vram_line_ptr
        lbra     other_char
not_CR:
        cmpa    #$0a
        bne not_LF
        leay    VRAM_LIGNE,y
        ldu     vram_line_ptr
        leau    VRAM_LIGNE,u
        stu     vram_line_ptr

 CHECK_SCROLL:
        pshs d,x,y
        ; 1. Calcule la distance entre la ligne actuelle et le haut de l'écran
        LDD     vram_line_ptr
        SUBD    #VRAM_BASE              ; Offset absolu de la ligne actuelle
        ifne    CARTE_MONO
        LSRA                            ; octets -> cases (2 octets par case)
        RORB
        endc
        SUBD    SCREEN_START_OFFSET     ; Distance relative depuis le haut de l'écran visible

        CMPD    #2400                   ; A-t-on dépassé 30 lignes (2400 octets) ?
        BLO     END_SCROLL              ; Non, on est toujours dans l'écran visible. On quitte.

        ; 2. --- L'écran est plein, on doit scroller d'une ligne ! ---
        LDD     SCREEN_START_OFFSET
        ADDD    #80                     ; On descend la "caméra" d'une ligne
        STD     SCREEN_START_OFFSET

        ; 3. --- Vérifie si on a atteint la fin de la page de 4 Ko ---
        CMPD    #1696                   ; Limite max de la caméra (4096 - 2400)
        BLO     UPDATE_CRTC_R12_R13     ; On a encore de la place, on met juste à jour le CRTC

        ; 4. --- FIN DU CAHIER : On tourne la page ! ---
        ; On remet les pointeurs au tout début de la VRAM
        LDY     #VRAM_BASE
        STY     vram_line_ptr
        STY     VRAM_PTR

        ; On remet la caméra en haut
        ldd     #-1
        STD     SCREEN_START_OFFSET

        ; On change de page physique dans le registre $A120
        LDA     CUR_PAGE
        INCA
        ANDA    #$07                    ; Sécurité : on boucle de la page 7 à la page 0
        STA     CUR_PAGE
        STA     VRAM_CTRL
        ; (Note : La page suivante devrait idéalement être effacée avec des espaces par l'OS)

UPDATE_CRTC_R12_R13:
        ; 5. --- Mise à jour matérielle du 68B45 ---
        LDD     SCREEN_START_OFFSET     ; D = A (High) et B (Low)

        PSHS    A                       ; Sauvegarde l'octet de poids fort
        LDA     #12                     ; Registre R12 (Start Address High)
        STA     $A100
        PULS    A
        STA     $A101

        LDA     #13                     ; Registre R13 (Start Address Low)
        STA     $A100
        STB     $A101

END_SCROLL:
        puls d,x,y
        ; Retour au traitement du caractère suivant (NEXT_CHAR)

        bra other_char
not_LF:
        cmpa    #08
        bne not_BS
        leay    -VRAM_PAS,y
        bra other_char
not_BS:
; --- GESTION DES FLÈCHES DIRECTIONNELLES ---
        cmpa    #$80            ; KEY_UP ?
        bne     not_UP
        leay    -VRAM_LIGNE,y   ; Recule d'une ligne
        ldu     vram_line_ptr
        leau    -VRAM_LIGNE,u   ; Met à jour le début de ligne pour le CR
        stu     vram_line_ptr
        bra     other_char
not_UP:
        cmpa    #$81            ; KEY_DOWN ?
        bne     not_DOWN
        leay    VRAM_LIGNE,y    ; Avance d'une ligne
        ldu     vram_line_ptr
        leau    VRAM_LIGNE,u    ; Met à jour le début de ligne pour le CR
        stu     vram_line_ptr
        bra     other_char
not_DOWN:
        cmpa    #$82            ; KEY_LEFT ?
        bne     not_LEFT
        leay    -VRAM_PAS,y     ; Recule d'un caractère
        bra     other_char
not_LEFT:
        cmpa    #$83            ; KEY_RIGHT ?
        bne     not_RIGHT
        leay    VRAM_PAS,y      ; Avance d'un caractère
        bra     other_char
not_RIGHT:

        ; --- AFFICHAGE STANDARD ---
        STA     ,y              ; Écrit le caractère ASCII sur la carte vidéo

        LDu     #COLOR_BUF      ; ... et sa couleur, 4 Ko plus haut
        clra
        leau    D,u
        lda     ,u
        STA     VRAM_COL_OFS,y
        LEAY    VRAM_PAS,y

other_char:
        ; --- Avance dans le buffer ---
        INCB                    ; Avance l'index de lecture (boucle 255->0 automatiquement)

        ; --- GESTION DU CAHIER (Pagination 8 Ko) ---
        CMPy    #VRAM_END       ; A-t-on dépassé $9FFF ?[cite: 3]
        Bne     NEXT_CHAR
        ; Oui : on change de page !
        LDy     #VRAM_BASE      ; On revient au début de la fenêtre mémoire ($8000)[cite: 3]
        sty     vram_line_ptr
        sty     VRAM_PTR
        LDA     CUR_PAGE
        INCA                    ; Page + 1
        ANDA    #$07            ; Sécurité : on garde la page entre 0 et 7
        STA     CUR_PAGE
        STA     VRAM_CTRL

NEXT_CHAR:
        ; --- Vérifications de fin de boucle ---
        CMPB    BUF_HEAD        ; Le buffer est-il entièrement vidé ?
        BEQ     UPDATE_PTRS

        LEAx    -1,x            ; Décrémente le compteur de temps VSYNC
        lBNE     LOOP_CHAR       ; S'il reste du temps et des caractères, on boucle

UPDATE_PTRS:
        ; 4. Sauvegarde le travail accompli pour la prochaine trame
        STB     BUF_TAIL
        STy     VRAM_PTR

        ; (V4 : rien à rendre au 68B45, la VRAM est à lui hors des accès)


        LBRA    UPDATE_CURSOR

    section .ext
; ===================================================================
; Zone_IRQ - la console dans le rectangle cz_* (video.asm, Console_Zone)
; 1. Un travail de rangées en cours (cz_op) passe d'abord, 2 rangées par
;    trame (2 x 2 plans x largeur : dans le retour de trame) :
;    1 défilement : la rangée suivante est recopiée sur cz_ptr ; au bout,
;      la dernière rangée est effacée (le travail devient 2, 1 rangée) ;
;    2 effacement : espaces, attribut char_attribut.
;    Rien d'autre dans cette trame : le texte attend.
; 2. Sinon, au plus 8 caractères : CR, LF (en bas : défilement), BS (pas
;    plus à gauche que la zone), $80-$83 et les autres codes < $20
;    ignorés ; au bord droit, retour à la ligne avant le caractère.
; ===================================================================
X_Zone_IRQ:
        LDA     CUR_PAGE
        STA     VRAM_CTRL
        TST     cz_op
        BEQ     Zi_Texte
        LDA     #2
        STA     cz_cpt          ; rangées permises dans cette trame
Zi_Rangee:
        TST     cz_n
        BNE     Zi_Travail
        LDA     cz_op           ; fin du travail
        CMPA    #1
        BNE     Zi_Libre
        LDA     #2              ; défilement fini : effacer la dernière rangée
        STA     cz_op
        LDA     #1
        STA     cz_n
        BRA     Zi_Rangee
Zi_Libre:
        CLR     cz_op
        LBRA    UPDATE_CURSOR
Zi_Travail:
        CLRE
        LDF     cz_l            ; W = largeur
        LDX     cz_ptr
        LDA     cz_op
        CMPA    #1
        BNE     Zi_Efface
        ifne    CARTE_MONO
        ADDF    cz_l            ; mono : caractère et couleur se suivent,
        LEAU    VRAM_LIGNE,X    ; une rangée = un bloc de 2 x largeur
        TFM     U+,X+
        BRA     Zi_Suivante
Zi_Efface:
        LDA     #$20            ; espace, attribut char_attribut
        LDB     char_attribut
Zi_EffCase:
        STD     ,X++
        DECF
        BNE     Zi_EffCase
        else
        LEAU    80,X            ; défilement : rangée suivante -> celle-ci
        TFM     U+,X+
        LDF     cz_l
        LDX     cz_ptr
        LEAU    VRAM_COL_OFS+80,X
        LEAX    VRAM_COL_OFS,X
        TFM     U+,X+
        BRA     Zi_Suivante
Zi_Efface:
        LDU     #Zi_Espace
        TFM     U,X+
        LDF     cz_l
        LDX     cz_ptr
        LEAX    VRAM_COL_OFS,X
        LDU     #char_attribut
        TFM     U,X+
        endc
Zi_Suivante:
        LDX     cz_ptr
        LEAX    VRAM_LIGNE,X
        STX     cz_ptr
        DEC     cz_n
        DEC     cz_cpt
        BNE     Zi_Rangee
        LBRA    UPDATE_CURSOR
        ifeq    CARTE_MONO
Zi_Espace:
        FCB     $20
        endc

Zi_Texte:
        LDA     BUF_HEAD
        CMPA    BUF_TAIL
        LBEQ    UPDATE_CURSOR
        LDA     #8
        STA     cz_cpt
        LDB     BUF_TAIL
        LDY     VRAM_PTR
Zi_Car:
        LDU     #ASCII_BUF
        CLRA
        LEAU    D,U
        LDA     ,U
        CMPA    #$0D
        BNE     Zi_PasCR
        LDY     vram_line_ptr
        BRA     Zi_Pris
Zi_PasCR:
        CMPA    #$0A
        BNE     Zi_PasLF
        BSR     Zi_Ligne        ; C = 1 : un défilement commence
        INCB                    ; le LF est consommé dans les deux cas
        BCS     Zi_Stop
        BRA     Zi_Compte
Zi_PasLF:
        CMPA    #$08
        BNE     Zi_PasBS
        CMPY    vram_line_ptr
        BLS     Zi_Pris
        LEAY    -VRAM_PAS,Y
        BRA     Zi_Pris
Zi_PasBS:
        CMPA    #$20
        BLO     Zi_Pris         ; autres codes de contrôle : rien
        CMPA    #$83
        BHI     Zi_Ecrit
        CMPA    #$80
        BHS     Zi_Pris         ; flèches de read_line : rien
Zi_Ecrit:
        PSHS    D
        TFR     Y,D
        SUBD    vram_line_ptr
        ifne    CARTE_MONO
        LSRB                    ; octets -> colonne (< 80 : B suffit)
        endc
        CMPB    cz_l
        PULS    D
        BLO     Zi_Pose
        PSHS    A               ; bord droit : à la ligne d'abord
        LDY     vram_line_ptr
        BSR     Zi_Ligne
        PULS    A
        BCS     Zi_Stop         ; défilement : le caractère attend
Zi_Pose:
        STA     ,Y
        LDU     #COLOR_BUF
        CLRA
        LEAU    D,U
        LDA     ,U
        STA     VRAM_COL_OFS,Y
        LEAY    VRAM_PAS,Y
Zi_Pris:
        INCB
Zi_Compte:
        CMPB    BUF_HEAD
        BEQ     Zi_Stop
        DEC     cz_cpt
        BNE     Zi_Car
Zi_Stop:
        STB     BUF_TAIL
        STY     VRAM_PTR
        LBRA    UPDATE_CURSOR

; Zi_Ligne : rangée suivante (Y suit, même colonne). Sur la dernière rangée
; de la zone : lance le défilement (cz_op = 1), C = 1. Préserve B.
Zi_Ligne:
        LDX     vram_line_ptr
        CMPX    cz_bas
        BEQ     Zi_Defile
        LEAX    VRAM_LIGNE,X
        STX     vram_line_ptr
        LEAY    VRAM_LIGNE,Y
        ANDCC   #$FE
        RTS
Zi_Defile:
        LDX     cz_haut
        STX     cz_ptr
        LDA     cz_h
        DECA
        STA     cz_n
        LDA     #1
        STA     cz_op
        ORCC    #$01
        RTS

    section .code
Zone_IRQ:
    jmp     [ExtV+EXTV_ZONEIRQ]

UPDATE_CURSOR:
        ; 1. Calcul de l'offset du curseur (X contient la nouvelle position)
        LDX     VRAM_PTR        ; Récupère la position actuelle
        TFR     X,D             ; Copie X dans l'accumulateur D (D = A:B)
        ifne    CARTE_MONO
        SUBD    #VRAM_BASE      ; octets -> cases, puis le -1 du 68B45
        LSRA
        RORB
        SUBD    #1
        else
        SUBD    #VRAM_BASE+1          ; Soustrait la base VRAM pour obtenir un offset de 0 à 4095[cite: 1]
        endc

        ; À ce stade :
        ; A contient l'octet de poids fort (High Byte)
        ; B contient l'octet de poids faible (Low Byte)

        ; 2. Mise à jour du registre R14 (Cursor High)
        PSHS    A               ; Sauvegarde l'octet de poids fort
        LDA     #14             ; Sélectionne le registre R14 du 68B45
        STA     CRTC_RS           ; Écrit dans le port d'Index[cite: 1]
        PULS    A               ; Récupère l'octet de poids fort
        STA     CRTC_DATA           ; Écrit dans le port de Données[cite: 1]

        ; 3. Mise à jour du registre R15 (Cursor Low)
        LDA     #15             ; Sélectionne le registre R15 du 68B45
        STA     CRTC_RS           ; Écrit dans le port d'Index[cite: 1]
        STB     CRTC_DATA
        ; Écrit l'octet de poids faible (qui était resté dans B)[cite: 1]

 ; ---------------------------------------------------------
; MOTEUR AUDIO 2 VOIES (Exécuté à chaque VSYNC)
; ---------------------------------------------------------
    section .ext
X_Audio:
        LDX     MUSIC_PTR       ; Y a-t-il une musique chargée ?
        BEQ     XA_Fin       ; Si X = 0000, le séquenceur est à l'arrêt

        TST     MUSIC_TIMER     ; Est-ce le moment de changer de note ?
        BEQ     AUDIO_READ_ROW  ; Si timer = 0, on lit la ligne suivante de la partition

        DEC     MUSIC_TIMER     ; Sinon, on décompte juste une frame...
        BRA     XA_Fin       ; ... et on quitte !

AUDIO_READ_ROW:
        ; --- Lecture Voie 1 ---
        LDD     ,X++            ; Lit la note V1 (16 bits) et avance X de 2
        CMPD    #FIN_MUSIQUE    ; Est-ce le code de fin ?
        BEQ     AUDIO_STOP      ; Oui -> on arrête le moteur

        STD     PTM_T2_MSB      ; Non -> on envoie la note directement au Timer 2
        LDW     #$0800          ; ... et à la voie A de l'AY (volume R8, période R0)
        JSR     Ay_Note

        ; --- Lecture Voie 2 ---
        LDD     ,X++            ; Lit la note V2 (16 bits) et avance X de 2
        STD     PTM_T3_MSB      ; On l'envoie au Timer 3
        LDW     #$0A04          ; ... et à la voie C de l'AY (volume R10, période R4)
        JSR     Ay_Note

        ; --- Lecture Durée ---
        LDA     ,X+           ; Lit la durée (8 bits) et avance X de 1
        STA     MUSIC_TIMER     ; Recharge le compteur pour attendre
        STX     MUSIC_PTR       ; Sauvegarde la nouvelle position du pointeur
        BRA     XA_Fin

AUDIO_STOP:
        LDX     #$0000
        STX     MUSIC_PTR       ; Remet le pointeur à 0 (Moteur en pause)
        sTX     PTM_T2_MSB
        stx     PTM_T3_MSB
        JSR     Ay_Silence      ; AY : volumes à 0
        ; --- On coupe VRAIMENT le son (Désactive les sorties O2 et O3) ---
        ; 1. On coupe O2 (Voie 1) et on pointe vers CR3 (bit 0 = 0)
        ; $02 = %00000010 (Sortie OFF, Horloge E)
        ;LDA     #$00
        ;STA     PTM_CR2

        ; 2. On coupe O3 (Voie 2)
        ; $02 = %00000010 (Sortie OFF, Horloge E)
        ;LDA     #$02
        ;STA     PTM_CR1_CR3

        ; 3. On maintient O2 coupée et on repointe vers CR1 (bit 0 = 1) pour ta VSYNC
        ; $03 = %00000011 (Sortie OFF, Horloge E, Pointe CR1)
        ;LDA     #$03
        ;STA     PTM_CR2
XA_Fin:
        RTS
    section .code
AUDIO_UPDATE:
        JSR     [ExtV+EXTV_AUDIO]     ; le séquenceur (BIOS2), ou rien
AUDIO_END:



END_IRQ:
        ; --- SONDE TEMPORAIRE (à retirer) : ',' atteint le RTI ---
        ;lda     #','
        ;jsr     DiagPut
        lda #$dc
        sta     CR_key
        rti







handler_SWI:
        rti
handler_SWI2:
        rti
handler_SWI3:
        rti

handler_FIRQ:

        RTI



; Les deux ACIA (liaison série, clavier) partagent la NMI, déclenchée sur
; un FRONT : tant que l'une tient la ligne basse, l'autre n'en crée pas de
; nouveau. On sert donc les deux, en boucle, jusqu'à ce qu'aucune n'ait
; plus d'octet. (Avant : un octet série servi, RTI ; un octet clavier
; arrivé en même temps attendait que l'IRQ VSYNC coupe et rende les IT du
; clavier, une trame plus tard : sous le flux de MINITEL, le clavier
; perdait des codes.)
handler_NMI:
        lda     SR
        anda    #$01
        beq NOT_RS232
        TST     serie_brute
        BNE     NMI_Brut
        LDX     write_line_ptr
        LDA     RDR
        CMPA    #$01
        BEQ     break
        STA     ,X+
        CLR     ,X
        CMPX    #line_ptr+127
        BLS     not_full
        LDA     #$07
        JSR     [table_function_ram+sys_PrintChar]
        BRA     NOT_RS232
not_full:
        STX     write_line_ptr
        BRA     NOT_RS232
break:
        ; Ctrl+A sur la liaison série : le SECOURS (main.asm), quoi qu'il
        ; tourne. Il repart d'une pile neuve et démasque lui-même les IT.
        LDX     #break_msg
        JSR     [table_function_ram+sys_PrintString]
        LDX     #Secours
        STX     $0C,S           ; frame native 14 octets : PC à S+12-13
        RTI
NMI_Brut:
        ; Mode brut (MINITEL...) : l'octet va dans l'anneau, rien d'autre.
        LDA     RDR
        LDB     serie_tete
        INCB
        CMPB    serie_queue
        BEQ     Brut_Plein          ; anneau plein : on le perd
        STB     serie_tete
        DECB
        LDX     #serie_buf
        ABX                         ; B non signé (B,X irait à -128)
        STA     ,X
Brut_Plein:
NOT_RS232:
        lda     SR_key
        anda    #$01
        bne keyboard2
        RTI
keyboard2:
        lda SR_key
        lda RDR_key
        TST   kbd_muet          ; écho d'un envoi au clavier, accusé décalé :
        LBNE  handler_NMI       ; jetés
        STA   SCAN_CODE
        LDB   kbd_tete          ; et dans la file (pleine : l'octet est perdu)
        LDX   #kbd_buf
        STA   B,X               ; B < 16 : positif
        INCB
        ANDB  #15
        CMPB  kbd_queue
        BEQ   Kb_Plein
        STB   kbd_tete
Kb_Plein:
        CMPA  #$76              ; Échap (appui ou relâchement) : drapeau
        BNE   Kb_PasEchap
        LDB   #$80
        STB   kbd_echap
Kb_PasEchap:
        ;ldx key2_ptr
        ;sta ,x+
        ;cmpx #key2_buffer+256
        ;bne NMI_end
        ;ldx #key2_buffer
NMI_end:
        LDA   #1
        STA   NEW_CODE
        ;stx key2_ptr
        LBRA  handler_NMI       ; un octet série a pu arriver entre-temps

; ===================================================================
; hdlr_TRAP - Trappe 6309 ($FFF0)
; Déclenchée par une division par zéro (DIVD/DIVQ/DIVX) ou par un
; opcode illégal. Les diviseurs nuls sont normalement protégés dans
; les routines (Div16_Fast, Divide_Y_by_X_16) : ce handler est un
; filet de sécurité. On affiche un message puis on se fige, afin de
; faciliter le débogage sur matériel.
; ===================================================================
handler_TRAP:
        ; Frame native 6309 = 14 octets :
        ;   CC=0  A=1  B=2  E=3  F=4  DP=5  X=6-7  Y=8-9  U=10-11  PC=12-13
        ; Tout est d'abord copié en RAM (trap_frame, trap_info), IRQ et FIRQ
        ; masquées : le programme MONITEUR (commande R) l'affiche après le
        ; redémarrage à chaud, qui n'efface pas la BSS. Ici : une ligne, une
        ; touche, puis OSM-VISION est rechargé depuis la carte (sa copie en
        ; RAM a pu être abîmée par le programme fautif).
        lda     0,s                     ; CC d'origine
        sta     trap_frame+26
        orcc    #%11010000              ; masque I et F
        ; Un TRAP dans le handler lui-même : on se fige sans rien imprimer.
        lda     trap_active
        lbne    trap_halt
        inca
        sta     trap_active
        tfr     s,d
        std     trap_frame+14           ; SP d'origine
        tfr     d,x                     ; X = frame
        ldy     #trap_frame
        ldb     #14
trap_copy_frame:
        lda     ,x+
        sta     ,y+
        decb
        bne     trap_copy_frame
        lda     trap_frame+26           ; le bit F d'origine dans le CC copié
        anda    #%01000000
        ora     trap_frame
        sta     trap_frame
        ldy     #trap_frame+16          ; X : la pile d'avant le TRAP
        ldb     #10
trap_copy_stk:
        lda     ,x+
        sta     ,y+
        decb
        bne     trap_copy_stk
        lda     BUF_HEAD                ; le tampon vidéo, avant tout CLR
        sta     trap_frame+27
        lda     BUF_TAIL
        sta     trap_frame+28
        ; --- trap_info : l'état de la machine (format dans ram.asm) ---
        ldy     #trap_info
        lda     #$A5
        sta     ,y+
        lda     current_page
        sta     ,y+
        lda     CUR_PAGE
        sta     ,y+
        ldd     SCREEN_START_OFFSET
        std     ,y++
        ldd     VRAM_PTR
        std     ,y++
        ldd     vsync_tick
        std     ,y++
        std     ,y++                    ; (refait plus bas, IRQ démasquées)
        ldd     read_line_ptr
        std     ,y++
        ldd     write_line_ptr
        std     ,y++
        ldx     trap_frame+12           ; 16 octets à partir de PC-4
        leax    -4,x
        ldb     #16
trap_copy_op:
        lda     ,x+
        sta     ,y+
        decb
        bne     trap_copy_op

        lds     #RAM_TOP                ; le contexte trappé est abandonné
        CLR     BUF_HEAD                ; le rendu d'écran est peut-être en cause
        CLR     BUF_TAIL
        andcc   #%00101111              ; IRQ + FIRQ : PUTCHARV en a besoin
        ldx     #6000                   ; ~26 ms (> 1 trame), puis vsync_tick relu :
trap_att:                               ; s'il a bougé, l'IRQ VSYNC vit
        leax    -1,x
        bne     trap_att
        ldd     vsync_tick
        std     trap_info+9

        ldx     #trap_msg               ; TRAP PC=xxxx [4 octets à PC-2]
        jsr     [table_function_ram+sys_PrintString]
        ldd     trap_frame+12
        jsr     [table_function_ram+sys_PrintHexWord]
        ldx     #trap_op_msg
        jsr     [table_function_ram+sys_PrintString]
        ldx     #trap_info+17
        ldb     #4
trap_op4:
        lda     ,x+
        jsr     [table_function_ram+sys_PrintHexChar]
        decb
        bne     trap_op4
        ldx     #trap_suite_msg
        jsr     [table_function_ram+sys_PrintString]
        ; une touche (clavier ou liaison série), puis redémarrage à chaud
        clr     NEW_CODE
        ldx     write_line_ptr
trap_touche:
        cmpx    write_line_ptr
        bne     trap_repart
        tst     NEW_CODE
        beq     trap_touche
trap_repart:
        clr     trap_active
        lda     #1
        sta     boot_chaud
        jmp     Redemarrage
trap_halt:
        bra     trap_halt

trap_msg:
        FCB     $0A,$0D
        FCN     "TRAP 6309  PC="
trap_op_msg:
        FCN     "  octets PC-2 : "
trap_suite_msg:
        FCB     $0A,$0D
        FCC     "Une touche : retour a OSM-VISION (MONITEUR, commande R : details)"
        FCB     $0A,$0D,0
break_msg:
        FCB     $0D,$0A
        FCN     "break in"


        END
