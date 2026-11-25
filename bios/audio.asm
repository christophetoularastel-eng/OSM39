; ===================================================================
        include "hardware.inc"
        include "sysfunc.inc"


; =========================================================
; --- CONSTANTES MATERIELLES : 68B40 PTM ---
; =========================================================
PTM_BASE    EQU $A080       ; /!\ A REMPLACER par ton adresse matérielle !

PTM_CR1_CR3 EQU PTM_BASE+0  ; Registres de contrôle 1 ou 3 (selon le bit 0 de CR2)
PTM_CR2     EQU PTM_BASE+1  ; Registre de contrôle 2
PTM_T1_MSB  EQU PTM_BASE+2  ; Timer 1 (Ta VSYNC)
PTM_T2_MSB  EQU PTM_BASE+4  ; Timer 2 (Son Voie 1) - MSB, LSB est à +5
PTM_T3_MSB  EQU PTM_BASE+6  ; Timer 3 (Son Voie 2) - MSB, LSB est à +7

; =========================================================
; --- CONSTANTES AUDIO (Horloge E = 1.8432 MHz) ---
; =========================================================

; --- CONSTANTES (Horloge E = 1.8432 MHz) ---
NOTE_SILENCE EQU $0000  ; (Astuce : génère des ultrasons inaudibles)
NOTE_C4      EQU $0DC2  ; Do 4
NOTE_E4      EQU $0AEB  ; Mi 4
NOTE_G4      EQU $092E  ; Sol 4
NOTE_C5      EQU $06E0  ; Do 5
NOTE_E5      EQU $0575  ; Mi 5
FIN_MUSIQUE  EQU $FFFF  ; Marqueur de fin
SND_BUF_SIZE EQU 128    ; taille du tampon SND_BUF de ram.asm (DOIT rester identique)
SND_REARM    EQU 1      ; 1 = snd_play réactive les sorties O2/O3 (voir la note dans snd_play)


; =========================================================
; --- VARIABLES EN RAM (Si tu veux garder l'état) ---
; =========================================================
    export init_audio, boot_jingle, snd_play, snd_stop, Ay_Note, Ay_Silence
    export X_boot_jingle, X_snd_play, X_snd_stop
    include "ext.inc"
    import  ExtV
    import video_wait_vsync
    import MUSIC_PTR, MUSIC_TIMER, SND_BUF
    section .code

init_audio:
    LDD #0
    STD PTM_T2_MSB
    LDD #0
    STD PTM_T3_MSB
    ; Pointer vers CR3
    LDA #$00
    STA PTM_CR2

    ; Configurer Timer 3 (O3 ON, Continu, pas d'IRQ)
    LDA #%10000010
    STA PTM_CR1_CR3

    ; Configurer Timer 2 (O2 ON, Continu, pas d'IRQ, pointe CR1)
    LDA #%10000011
    STA PTM_CR2
    JMP Ay_Silence
    section .code
; =========================================================
; BOOT_JINGLE : "Ta-Da-Daaa!", joué par le séquenceur (6840 et AY)
; =========================================================
X_boot_jingle:
    LDX #SONG_TADA_2V
    JSR snd_play
    LDE #55                 ; durée de la partition : 8 + 6 + 40 + 1 trames
    JMP video_wait_vsync

; --- LA PARTITION (5 octets par ligne) ---
; Format: FDB Note_V1, Note_V2 / FCB Durée
SONG_TADA_2V:
    FDB NOTE_C4,NOTE_C5   ; V1: Do4 (Basse) | V2: Do5 (Mélodie)
    FCB 7                  ; 8 trames (une ligne dure durée+1)

    FDB NOTE_C4,NOTE_E5   ; V1: Do4 (Tenue) | V2: Mi5 (Mélodie monte)
    FCB 5

    FDB NOTE_C4,NOTE_G4   ; V1: Do4 (Tenue) | V2: Sol4 (Accord parfait final)
    FCB 39

    FDB NOTE_SILENCE,NOTE_SILENCE ; On coupe le son proprement
    FCB 0

    FDB FIN_MUSIQUE        ; Fin de lecture


; =========================================================
; SERVICES SON POUR LES APPLICATIONS
;   table des fonctions : sys_snd_play, sys_snd_stop
;
; Le séquenceur (AUDIO_UPDATE, handler IRQ) lit la partition à CHAQUE VSYNC
; dans la page utilisateur alors mappée ($0000-$7FFF). Une partition qui vit
; dans la page d'une application devient donc illisible (ou lue de travers)
; dès que la page change : sortie de l'application, FS_LoadFile vers une autre
; page, etc. snd_play règle le problème à la source : la partition est COPIÉE
; en RAM système (SND_BUF), que le séquenceur lit quelle que soit la page.
; =========================================================

; ---------------------------------------------------------
; snd_play
;   Entrée : X = partition, dans la page COURANTE :
;            FDB voix1,voix2 / FCB durée ... FDB $FFFF
;            (une ligne dure durée+1 trames ; voir AUDIO_UPDATE dans IT.asm)
;   Sortie : rien ; toutes les registres sont préservés.
;   Une partition déjà en RAM système ou en ROM (adresse >= $C000) est jouée
;   sans copie. Au-delà de SND_BUF_SIZE octets la partition est tronquée
;   (marqueur de fin ajouté). Le son précédent est interrompu tout de suite.
; ---------------------------------------------------------
X_snd_play:
        pshs    d,x,y,u,cc
        orcc    #%00010000      ; section critique : copie puis démarrage atomiques
        cmpx    #$C000
        bhs     snd_go          ; déjà hors de la fenêtre paginée : lue telle quelle
        ldy     #SND_BUF
snd_row:
        ldd     ,x              ; première voix de la ligne
        cmpd    #FIN_MUSIQUE
        beq     snd_term        ; fin de la partition source
        cmpy    #SND_BUF+SND_BUF_SIZE-7
        bhi     snd_term        ; plus de place pour une ligne + le marqueur : on tronque
        ldd     ,x++            ; copie 5 octets : voix 1, voix 2, durée
        std     ,y++
        ldd     ,x++
        std     ,y++
        lda     ,x+
        sta     ,y+
        bra     snd_row
snd_term:
        ldd     #FIN_MUSIQUE
        std     ,y
        ldx     #SND_BUF
snd_go:
        IFNE    SND_REARM
        ; AUDIO_STOP coupe les sorties (bit 7 des CR = 0). On les réactive comme
        ; init_audio, à chaque lecture, pour que le son suivant ne soit jamais muet.
        ; (IRQ masquée : pas de conflit avec AUDIO_STOP.)
        lda     #$00
        sta     PTM_CR2         ; $A080 -> CR3
        lda     #%10000010      ; CR3 : O3 ON, continu, pas d'IRQ
        sta     PTM_CR1_CR3
        lda     #%10000011      ; CR2 : O2 ON, continu, pointe CR1 (VSYNC)
        sta     PTM_CR2
        ENDC
        jsr     Ay_Silence      ; mixeur de l'AY remis (un programme a pu le changer)
        clr     MUSIC_TIMER     ; démarre à la trame suivante, sans attendre la note en cours
        stx     MUSIC_PTR
        puls    d,x,y,u,cc
        rts

; ---------------------------------------------------------
; snd_stop
;   Coupe le son. Le séquenceur lit un marqueur de fin placé en ROM (lisible
;   dans toutes les pages) et exécute son AUDIO_STOP à la trame suivante
;   (17 ms au plus). Peut être appelé à tout moment, même si rien ne joue.
; ---------------------------------------------------------
X_snd_stop:
        pshs    x,cc
        orcc    #%00010000
        clr     MUSIC_TIMER
        ldx     #snd_end_marker
        stx     MUSIC_PTR
        puls    x,cc
        rts

snd_end_marker:
        FDB     FIN_MUSIQUE     ; en ROM : lisible quelle que soit la page mappée

; =========================================================
; AY-3-8910 (carte SD-KBD-SON) : le séquenceur joue la voix 1 sur la voie
; A et la voix 2 sur la voie C (la voie B de la puce de la carte est
; muette : R9 ne retient rien). Même partition que le 6840 : le compte N
; d'un timer donne f = E / (2 (N+1)), la période de l'AY f = E / (16 TP),
; donc TP = (N+1) / 8, plafonné à $FFF (12 bits).
; =========================================================

; ---------------------------------------------------------
; Ay_Note : D = compte du 6840 (NOTE_SILENCE : voie muette),
;           E = registre de volume, F = registre de période basse
;           (W = $0800 : voie A ; $0A04 : voie C).
;   Volume 15. Détruit D et W ; préserve X, Y, U.
; ---------------------------------------------------------
Ay_Note:
        cmpd    #NOTE_SILENCE
        beq     an_muet
        addd    #1
        lsra                    ; (N+1) / 8
        rorb
        lsra
        rorb
        lsra
        rorb
        cmpd    #$0FFF
        bls     an_per
        ldd     #$0FFF
an_per:
        stf     AY_ADR          ; période basse puis haute
        stb     AY_DATA
        incf
        stf     AY_ADR
        sta     AY_DATA
        lda     #15
        bra     an_vol
an_muet:
        clra
an_vol:
        ste     AY_ADR
        sta     AY_DATA
        rts

    section .code
boot_jingle:
    jmp     [ExtV+EXTV_JINGLE]
snd_play:
    jmp     [ExtV+EXTV_SNDPLAY]
snd_stop:
    jmp     [ExtV+EXTV_SNDSTOP]

; ---------------------------------------------------------
; Ay_Silence : mixeur = tons A et C, sans bruit, ports A et B en entrée
;   (R7 = $3A) ; volumes à 0. Détruit D ; préserve X, Y, U, W.
; ---------------------------------------------------------
Ay_Silence:
        ldd     #$073A
        bsr     ay_ecrit
        ldd     #$0800
        bsr     ay_ecrit
        ldd     #$0900
        bsr     ay_ecrit
        ldd     #$0A00
ay_ecrit:
        sta     AY_ADR
        stb     AY_DATA
        rts
