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

NOTE_C4      EQU $0DC2  ; Do 4  (261.6 Hz)
NOTE_E4      EQU $0AEB  ; Mi 4  (329.6 Hz)
NOTE_G4      EQU $092E  ; Sol 4 (392.0 Hz)
NOTE_C5      EQU $06E0  ; Do 5  (523.2 Hz)
NOTE_E5     EQU $0575  ; Mi 5  (659.2 Hz) - Note de crête

; =========================================================
; --- VARIABLES EN RAM (Si tu veux garder l'état) ---
; =========================================================

MUSIC_PTR equ $C64F
MUSIC_TIMER equ $C651
FIN_MUSIQUE equ $ffff


video_wait_vsync equ $F692
init_audio  equ $f7bf

    section .code
JOUER_MUSIQUE:
    ;ORCC    #$50            ; Désactive les ITs pendant qu'on manipule le pointeur
    lde #01
    jsr video_wait_vsync
    jsr init_audio

    LDX     #SONG_TADA_2V   ; Charge l'adresse de ta partition
    STX     MUSIC_PTR       ; Donne-la au moteur audio
    CLR     MUSIC_TIMER     ; Force le moteur à lire la 1ère note à la prochaine VSYNC

    ;PULS    CC              ; Réactive les ITs, la magie opère !
    RTS

; --- LA PARTITION (5 octets par ligne) ---
; Format: FDB Note_V1, Note_V2 / FCB Durée
SONG_TADA_2V:
    FDB NOTE_C4,NOTE_C5   ; V1: Do4 (Basse) | V2: Do5 (Mélodie)
    FCB 6                  ; Durée = 6 frames

    FDB NOTE_C4,NOTE_E5   ; V1: Do4 (Tenue) | V2: Mi5 (Mélodie monte)
    FCB 6

    FDB NOTE_C4,NOTE_G4   ; V1: Do4 (Tenue) | V2: Sol4 (Accord parfait final)
    FCB 40


    FDB FIN_MUSIQUE        ; Fin de lecture
