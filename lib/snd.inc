; ===================================================================
; SND.INC - Séquenceur 2 voix : notes, format de partition, pointeurs
; ===================================================================
; Source unique du son pour les applications (OSM-VISION, BRIQUES,
; futures apps). Inclus via :   include "../lib/snd.inc"
; (SND_PTR/SND_TIMER derivent de MUSIC_PTR : hardware.inc doit etre
;  inclus AVANT ce fichier.)
;
; Démarrer un son : inclure lib/snd.asm dans le .code (après le point
; d'entrée, voir l'en-tête de ce fichier) puis, avec X = partition :
;       LDX  #partition
;       JSR  Snd_Start
; (Le déclencheur lui-même : PSHS CC / ORCC #%00010000 / CLR SND_TIMER
;  / STX SND_PTR / PULS CC / RTS — bascule pointeur+minuteur atomique.)
;
; Format d'une ligne : FDB voix1,voix2 / FCB durée (trames ; la ligne
; dure durée+1 trames à 60 Hz). Fin de partition : FDB SN_END.
; SN_SIL = silence. La note est le diviseur du timer :
;       N = 1843200 / (2 x fréquence).
;
; ATTENTION - la partition est lue par le séquenceur (handler IRQ) à
; CHAQUE VSYNC, dans la page ALORS MAPPÉE. Donc :
;   * ne jamais déclencher de son pendant un changement de page ;
;   * couper le son (partition de silence) avant de rendre la main :
;     la partition vit dans une zone que l'application suivante
;     réutilisera ;
;   * le BIOS propose sys_snd_play (services 66/68, sans thunk dans
;     bioslib.asm aujourd'hui) qui COPIE la partition en RAM système
;     (SND_BUF) et lève ce piège de page. À adopter en priorité pour
;     une nouvelle application -- après vérification que l'EPROM
;     montée sur la carte expose bien ces services (l'EPROM du
;     matériel est un build plus ancien que l'arbre).
; ===================================================================

; --- Pointeurs dans la RAM système ($C000, voir bios/ram.asm) ---
SND_PTR         equ MUSIC_PTR            ; pointeur de partition, 0 = arrêt
SND_TIMER       equ MUSIC_PTR+2          ; MUSIC_TIMER suit MUSIC_PTR

SN_SIL          equ $0000
SN_END          equ $FFFF

SN_C3    equ $1B85        ; 130.8 Hz
SN_Db3   equ $19F9        ; 138.6 Hz
SN_D3    equ $1884        ; 146.8 Hz
SN_Eb3   equ $1724        ; 155.6 Hz
SN_E3    equ $15D7        ; 164.8 Hz
SN_F3    equ $149D        ; 174.6 Hz
SN_Gb3   equ $1375        ; 185.0 Hz
SN_G3    equ $125E        ; 196.0 Hz
SN_Ab3   equ $1156        ; 207.7 Hz
SN_A3    equ $105D        ; 220.0 Hz
SN_Bb3   equ $0F71        ; 233.1 Hz
SN_B3    equ $0E94        ; 246.9 Hz
SN_C4    equ $0DC2        ; 261.6 Hz
SN_Db4   equ $0CFC        ; 277.2 Hz
SN_D4    equ $0C42        ; 293.7 Hz
SN_Eb4   equ $0B92        ; 311.1 Hz
SN_E4    equ $0AEB        ; 329.6 Hz
SN_F4    equ $0A4E        ; 349.2 Hz
SN_Gb4   equ $09BA        ; 370.0 Hz
SN_G4    equ $092F        ; 392.0 Hz
SN_Ab4   equ $08AB        ; 415.3 Hz
SN_A4    equ $082E        ; 440.0 Hz
SN_Bb4   equ $07B8        ; 466.2 Hz
SN_B4    equ $074A        ; 493.9 Hz
SN_C5    equ $06E1        ; 523.3 Hz
SN_Db5   equ $067E        ; 554.4 Hz
SN_D5    equ $0621        ; 587.3 Hz
SN_Eb5   equ $05C9        ; 622.3 Hz
SN_E5    equ $0575        ; 659.3 Hz
SN_F5    equ $0527        ; 698.5 Hz
SN_Gb5   equ $04DD        ; 740.0 Hz
SN_G5    equ $0497        ; 784.0 Hz
SN_Ab5   equ $0455        ; 830.6 Hz
SN_A5    equ $0417        ; 880.0 Hz
SN_Bb5   equ $03DC        ; 932.3 Hz
SN_B5    equ $03A5        ; 987.8 Hz
SN_C6    equ $0370        ; 1046.5 Hz
SN_Db6   equ $033F        ; 1108.7 Hz
SN_D6    equ $0310        ; 1174.7 Hz
SN_Eb6   equ $02E4        ; 1244.5 Hz
SN_E6    equ $02BA        ; 1318.5 Hz
SN_F6    equ $0293        ; 1396.9 Hz
SN_Gb6   equ $026E        ; 1480.0 Hz
SN_G6    equ $024B        ; 1568.0 Hz
SN_Ab6   equ $022A        ; 1661.2 Hz
SN_A6    equ $020B        ; 1760.0 Hz
SN_Bb6   equ $01EE        ; 1864.7 Hz
SN_B6    equ $01D2        ; 1975.5 Hz
