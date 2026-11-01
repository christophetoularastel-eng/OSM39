; ===================================================================
; SON.ASM - Maquette sonore : le 6840 en convertisseur numérique
; ===================================================================
; Application d'OSM-VISION (modèle apps/mire.asm). Elle vérifie à
; l'oreille qu'on peut sortir des échantillons, première étape vers la
; synthèse de la parole.
;
; PRINCIPE (datasheet EF6840, tables 3 et 6) :
;   * timer 2 en mode MONOCOUP, horloge E, sortie O2 active ($A3 dans
;     CR2 : bit 0 = 1 garde CR1 adressé en $A080). Ecrire ses latches
;     (STD TIMER2 : MSB puis LSB) initialise le compteur : O2 sort UNE
;     impulsion d'environ N périodes E, puis reste basse. N = 0 : silence ;
;   * timer 3 en mode CONTINU, sortie masquée (O3 au repos), latches
;     127 : son drapeau (bit 2 du registre d'état) se lève toutes les
;     128 périodes E = 14 400 Hz. On le scrute, puis on l'efface en lisant
;     le compteur 3 (lecture de l'état, puis du compteur : datasheet) ;
;   * à chaque drapeau, STD TIMER2 avec l'échantillon (0..120) : une
;     modulation de largeur d'impulsion à 14,4 kHz ; chaque échantillon
;     sort deux fois (7 200 échantillons par seconde). Le filtre RC de la
;     carte (10k / 4k7 / 47 nF, fc ~ 1,4 kHz) en fait le signal.
;     Essai précédent à 7,2 kHz (une impulsion par échantillon) : tout se
;     reconnaissait, mais la porteuse sifflait.
; IRQ masquées pendant la lecture (le séquenceur de musique et le VSYNC
; ne doivent pas toucher aux timers ni décaler l'échantillon). A la fin,
; les timers reviennent comme init_audio (bios/audio.asm) les met.
;
; Touches : 1 sinus 440 Hz, 2 carré 440 Hz, 3 balayage 100 -> 3000 Hz,
; 4 voyelles A E I O OU U, 5 souffle, Echap retour.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"
    include "../lib/ui.inc"
    include "../lib/vis.inc"

    export App_Start

; Services d'OSM-VISION utilisés : jusqu'à vis_Sound_Stop
VIS_REQUIS      equ (vis_Sound_Stop/2)+1

WIN_X           equ 18
WIN_Y           equ 5
WIN_W           equ 44
WIN_H           equ 14
TXT_X           equ WIN_X+3
ROW_ETAT        equ WIN_Y+11

MILIEU          equ 60          ; échantillon du silence (milieu de 0..120)
TICK            equ 127         ; timer 3 : 128 périodes E par impulsion
FS              equ 7200        ; échantillons par seconde (2 impulsions chacun)

    section .code

; -------------------------------------------------------------------
; Point d'entrée (offset 0). IRQ actives à l'entrée.
; -------------------------------------------------------------------
App_Start:
    ANDCC   #%11101111
    LDA     >VIS_COUNT_ADR      ; '>' : adressage étendu, pas direct
    CMPA    #VIS_REQUIS
    BHS     AS_VisOk
    CMPA    #(vis_MsgBox/2)+1
    BLO     AS_Abandon
    LDX     #TxtVisVieux
    LDY     #TxtTitre
    JSR     [VIS_TABLE+vis_MsgBox]
AS_Abandon:
    RTS
AS_VisOk:
    LDD     >vsync_tick         ; graine du souffle
    STD     Seed
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #WIN_X
    LDB     #WIN_Y
    LDW     #(WIN_W*256)+WIN_H
    LDY     #TxtTitre
    JSR     [VIS_TABLE+vis_Window]
    JSR     [VIS_TABLE+vis_Sync_End]
    LDX     #Menu
    LDB     #WIN_Y+2
AS_Menu:
    LDA     ,X
    BEQ     AS_Pret
    PSHS    B,X
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDX     1,S
    LDA     #TXT_X
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
    PULS    B,X
AS_Skip:
    LDA     ,X+
    BNE     AS_Skip
    INCB
    BRA     AS_Menu
AS_Pret:
    LDX     #TxtPret
    JSR     Etat

; -------------------------------------------------------------------
; Boucle : une touche, un son
; -------------------------------------------------------------------
Main_Loop:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #$1B
    BEQ     Quit
    CMPA    #'1'
    BLO     Main_Loop
    CMPA    #'5'
    BHI     Main_Loop
    SUBA    #'1'
    STA     Choix
    LDX     #TxtLecture
    JSR     Etat
    JSR     Ouvre_Dac
    LDB     Choix
    ASLB
    LDX     #Sons
    JSR     [B,X]
    JSR     Ferme_Dac
    LDX     #TxtPret
    JSR     Etat
    BRA     Main_Loop

Quit:
    RTS                         ; OSM-VISION restaure l'écran

; X = texte de la ligne d'état (complété d'espaces par le texte lui-même).
Etat:
    PSHS    X
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDX     ,S
    LDA     #TXT_X
    LDB     #ROW_ETAT
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    JSR     [VIS_TABLE+vis_Sync_End]
    PULS    X,PC

; -------------------------------------------------------------------
; Le 6840 en convertisseur
; -------------------------------------------------------------------
; Chaque échantillon sort DEUX fois (timer 3 à 128 périodes E) : la
; porteuse monte à 14,4 kHz, un octave au-dessus de 7,2 kHz, mieux
; filtrée par le RC de la carte et à peine audible. Une impulsion :
;       attendre le drapeau du timer 3, lire son compteur (efface le
;       drapeau), STD TIMER2 (Sample)
; Les calculs se glissent entre deux impulsions : 128 cycles chacune,
; moins l'attente et l'écriture (~25 cycles).
Ouvre_Dac:
    JSR     [VIS_TABLE+vis_Sound_Stop]
    ORCC    #%00010000          ; IRQ masquées jusqu'à Ferme_Dac
    LDA     #%10100010          ; CR2 : monocoup, E, O2 active ; bit 0 = 0 : CR3 en $A080
    STA     CR2
    LDA     #%00000010          ; CR3 : continu, E, sortie masquée, sans IRQ
    STA     CR3
    LDA     #%10100011          ; CR2 : idem, bit 0 = 1 : CR1 de nouveau en $A080
    STA     CR2
    LDD     #TICK
    STD     TIMER3
    LDD     #MILIEU
    STD     Sample
    STD     TIMER2
    RTS

; Comme init_audio : timers à 0, O2 et O3 en continu, CR1 adressé.
Ferme_Dac:
    LDD     #0
    STD     TIMER2
    STD     TIMER3
    LDA     #%00000000          ; CR2 : CR3 en $A080
    STA     CR2
    LDA     #%10000010          ; CR3 : O3 active, continu, E
    STA     CR3
    LDA     #%10000011          ; CR2 : O2 active, continu, E, CR1 en $A080
    STA     CR2
    ANDCC   #%11101111
    RTS

; --- 1 : sinus 440 Hz, 2 secondes ---
Son_Sinus:
    LDD     #FS*2
    STD     Count
    LDD     #0
    STD     Ph1
SS_Loop:
    LDA     STATUS
    BITA    #$04
    BEQ     SS_Loop
    LDD     TIMER3              ; efface le drapeau du timer 3
    LDD     Sample
    STD     TIMER2              ; relance l'impulsion
    LDD     Ph1
    ADDD    #INC_440
    STD     Ph1
    LDX     #TabSin
    TFR     A,B
    ABX
    LDB     ,X
    ADDB    #MILIEU
    CLRA
    STD     Sample
SS_2:
    LDA     STATUS
    BITA    #$04
    BEQ     SS_2
    LDD     TIMER3
    LDD     Sample
    STD     TIMER2
    LDD     Count
    SUBD    #1
    STD     Count
    BNE     SS_Loop
    RTS

; --- 2 : carré 440 Hz, même crête que le sinus ---
Son_Carre:
    LDD     #FS*2
    STD     Count
    LDD     #0
    STD     Ph1
SC_Loop:
    LDA     STATUS
    BITA    #$04
    BEQ     SC_Loop
    LDD     TIMER3
    LDD     Sample
    STD     TIMER2
    LDD     Ph1
    ADDD    #INC_440
    STD     Ph1
    LDB     #MILIEU+55
    TSTA
    BPL     SC_Haut
    LDB     #MILIEU-55
SC_Haut:
    CLRA
    STD     Sample
SC_2:
    LDA     STATUS
    BITA    #$04
    BEQ     SC_2
    LDD     TIMER3
    LDD     Sample
    STD     TIMER2
    LDD     Count
    SUBD    #1
    STD     Count
    BNE     SC_Loop
    RTS

; --- 3 : balayage 100 -> 3000 Hz (l'incrément grandit de 1 par
;     échantillon : ~3,7 s). On entend la coupure du filtre RC. ---
Son_Balayage:
    LDD     #INC_100
    STD     In1
    LDD     #0
    STD     Ph1
SB_Loop:
    LDA     STATUS
    BITA    #$04
    BEQ     SB_Loop
    LDD     TIMER3
    LDD     Sample
    STD     TIMER2
    LDD     Ph1
    ADDD    In1
    STD     Ph1
    LDX     #TabSin
    TFR     A,B
    ABX
    LDB     ,X
    ADDB    #MILIEU
    CLRA
    STD     Sample
SB_2:
    LDA     STATUS
    BITA    #$04
    BEQ     SB_2
    LDD     TIMER3
    LDD     Sample
    STD     TIMER2
    LDD     In1
    ADDD    #1
    STD     In1
    CMPD    #INC_3000
    BLO     SB_Loop
    RTS

; --- 4 : voyelles. Trois sinus aux fréquences des formants, remis en
;     phase à chaque période de voix (110 Hz) : le principe de S.A.M.
;     0,4 s par voyelle, 0,1 s de silence entre deux. ---
Son_Voyelles:
    LDY     #Voyelles
SV_Voy:
    LDD     ,Y
    BEQ     SV_Fin
    STD     In1
    LDD     2,Y
    STD     In2
    LDD     4,Y
    STD     In3
    PSHS    Y
    LDD     #(FS*4)/10
    STD     Count
    JSR     Voix
    LDD     #FS/10
    STD     Count
    JSR     Silence
    PULS    Y
    LEAY    6,Y
    BRA     SV_Voy
SV_Fin:
    RTS

; Count échantillons de voix aux incréments In1, In2, In3. Première
; moitié : période de voix, formants 1 et 2 ; seconde : formant 3,
; somme, compte.
Voix:
    LDD     #0
    STD     Ph1
    STD     Ph2
    STD     Ph3
    LDA     #PITCH_N
    STA     PitchC
VX_Loop:
    LDA     STATUS
    BITA    #$04
    BEQ     VX_Loop
    LDD     TIMER3
    LDD     Sample
    STD     TIMER2
    DEC     PitchC              ; début de période : formants remis en phase
    BNE     VX_Gen
    LDA     #PITCH_N
    STA     PitchC
    LDD     #0
    STD     Ph1
    STD     Ph2
    STD     Ph3
VX_Gen:
    LDD     Ph1
    ADDD    In1
    STD     Ph1
    LDX     #TabF1
    TFR     A,B
    ABX
    LDA     ,X
    STA     Acc
    LDD     Ph2
    ADDD    In2
    STD     Ph2
    LDX     #TabF2
    TFR     A,B
    ABX
    LDA     ,X
    ADDA    Acc
    STA     Acc
VX_2:
    LDA     STATUS
    BITA    #$04
    BEQ     VX_2
    LDD     TIMER3
    LDD     Sample
    STD     TIMER2
    LDD     Ph3
    ADDD    In3
    STD     Ph3
    LDX     #TabF3
    TFR     A,B
    ABX
    LDB     ,X
    ADDB    Acc                 ; somme signée, |s| <= 53
    ADDB    #MILIEU
    CLRA
    STD     Sample
    LDD     Count
    SUBD    #1
    STD     Count
    LBNE    VX_Loop
    RTS

; Count échantillons au milieu.
Silence:
    LDD     #MILIEU
    STD     Sample
SI_Loop:
    LDA     STATUS
    BITA    #$04
    BEQ     SI_Loop
    LDD     TIMER3
    LDD     Sample
    STD     TIMER2
SI_2:
    LDA     STATUS
    BITA    #$04
    BEQ     SI_2
    LDD     TIMER3
    LDD     Sample
    STD     TIMER2
    LDD     Count
    SUBD    #1
    STD     Count
    BNE     SI_Loop
    RTS

; --- 5 : souffle (bruit blanc, 2 s) : la matière des « ch », « f », « s ».
;     Générateur linéaire 16 bits (x 25173 + 13849, période 65 536 =
;     9 s) dont on garde l'octet de poids fort : un générateur 8 bits
;     se répète 28 fois par seconde et martèle. ---
Son_Souffle:
    LDD     #FS*2
    STD     Count
SF_Loop:
    LDA     STATUS
    BITA    #$04
    BEQ     SF_Loop
    LDD     TIMER3
    LDD     Sample
    STD     TIMER2
    LDD     Seed
    MULD    #25173              ; W = poids faible du produit
    ADDW    #13849
    STW     Seed
    TFR     E,B
    LSRB                        ; 0..63, centré sur MILIEU
    LSRB
    ADDB    #MILIEU-32
    CLRA
    STD     Sample
SF_2:
    LDA     STATUS
    BITA    #$04
    BEQ     SF_2
    LDD     TIMER3
    LDD     Sample
    STD     TIMER2
    LDD     Count
    SUBD    #1
    STD     Count
    BNE     SF_Loop
    RTS

; -------------------------------------------------------------------
; Données
; -------------------------------------------------------------------
Sons:           FDB Son_Sinus,Son_Carre,Son_Balayage,Son_Voyelles,Son_Souffle
TxtTitre:       FCN " SON "
TxtVisVieux:    FCN "OSM-VISION trop ancien pour SON."
TxtPret:        FCN "Pret.                       "
TxtLecture:     FCN "Lecture (IRQ masquees)...   "
Menu:
    FCN     "Le 6840 en convertisseur (14,4 kHz)"
    FCN     " "
    FCN     "1  La 440 Hz, sinus"
    FCN     "2  La 440 Hz, carre (meme crete)"
    FCN     "3  Balayage 100 -> 3000 Hz"
    FCN     "4  Voyelles A E I O OU U"
    FCN     "5  Souffle (bruit)"
    FCN     " "
    FCN     "Echap  retour"
    FCB     0

; Tables générées par un script jetable (Python) : sinus signés sur 256
; pas ; incréments = f x 65536 / 7200.
; sinus pur, amplitude 55
TabSin:
    FCB     0,1,3,4,5,7,8,9,11,12,13,15,16,17,19,20
    FCB     21,22,24,25,26,27,28,29,31,32,33,34,35,36,37,38
    FCB     39,40,41,42,43,43,44,45,46,46,47,48,49,49,50,50
    FCB     51,51,52,52,53,53,53,54,54,54,54,55,55,55,55,55
    FCB     55,55,55,55,55,55,54,54,54,54,53,53,53,52,52,51
    FCB     51,50,50,49,49,48,47,46,46,45,44,43,43,42,41,40
    FCB     39,38,37,36,35,34,33,32,31,29,28,27,26,25,24,22
    FCB     21,20,19,17,16,15,13,12,11,9,8,7,5,4,3,1
    FCB     0,-1,-3,-4,-5,-7,-8,-9,-11,-12,-13,-15,-16,-17,-19,-20
    FCB     -21,-22,-24,-25,-26,-27,-28,-29,-31,-32,-33,-34,-35,-36,-37,-38
    FCB     -39,-40,-41,-42,-43,-43,-44,-45,-46,-46,-47,-48,-49,-49,-50,-50
    FCB     -51,-51,-52,-52,-53,-53,-53,-54,-54,-54,-54,-55,-55,-55,-55,-55
    FCB     -55,-55,-55,-55,-55,-55,-54,-54,-54,-54,-53,-53,-53,-52,-52,-51
    FCB     -51,-50,-50,-49,-49,-48,-47,-46,-46,-45,-44,-43,-43,-42,-41,-40
    FCB     -39,-38,-37,-36,-35,-34,-33,-32,-31,-29,-28,-27,-26,-25,-24,-22
    FCB     -21,-20,-19,-17,-16,-15,-13,-12,-11,-9,-8,-7,-5,-4,-3,-1
; formant 1, amplitude 30
TabF1:
    FCB     0,1,1,2,3,4,4,5,6,7,7,8,9,9,10,11
    FCB     11,12,13,13,14,15,15,16,17,17,18,18,19,20,20,21
    FCB     21,22,22,23,23,24,24,25,25,25,26,26,26,27,27,27
    FCB     28,28,28,28,29,29,29,29,29,30,30,30,30,30,30,30
    FCB     30,30,30,30,30,30,30,30,29,29,29,29,29,28,28,28
    FCB     28,27,27,27,26,26,26,25,25,25,24,24,23,23,22,22
    FCB     21,21,20,20,19,18,18,17,17,16,15,15,14,13,13,12
    FCB     11,11,10,9,9,8,7,7,6,5,4,4,3,2,1,1
    FCB     0,-1,-1,-2,-3,-4,-4,-5,-6,-7,-7,-8,-9,-9,-10,-11
    FCB     -11,-12,-13,-13,-14,-15,-15,-16,-17,-17,-18,-18,-19,-20,-20,-21
    FCB     -21,-22,-22,-23,-23,-24,-24,-25,-25,-25,-26,-26,-26,-27,-27,-27
    FCB     -28,-28,-28,-28,-29,-29,-29,-29,-29,-30,-30,-30,-30,-30,-30,-30
    FCB     -30,-30,-30,-30,-30,-30,-30,-30,-29,-29,-29,-29,-29,-28,-28,-28
    FCB     -28,-27,-27,-27,-26,-26,-26,-25,-25,-25,-24,-24,-23,-23,-22,-22
    FCB     -21,-21,-20,-20,-19,-18,-18,-17,-17,-16,-15,-15,-14,-13,-13,-12
    FCB     -11,-11,-10,-9,-9,-8,-7,-7,-6,-5,-4,-4,-3,-2,-1,-1
; formant 2, amplitude 15
TabF2:
    FCB     0,0,1,1,1,2,2,3,3,3,4,4,4,5,5,5
    FCB     6,6,6,7,7,7,8,8,8,9,9,9,10,10,10,10
    FCB     11,11,11,11,12,12,12,12,12,13,13,13,13,13,14,14
    FCB     14,14,14,14,14,14,15,15,15,15,15,15,15,15,15,15
    FCB     15,15,15,15,15,15,15,15,15,15,15,14,14,14,14,14
    FCB     14,14,14,13,13,13,13,13,12,12,12,12,12,11,11,11
    FCB     11,10,10,10,10,9,9,9,8,8,8,7,7,7,6,6
    FCB     6,5,5,5,4,4,4,3,3,3,2,2,1,1,1,0
    FCB     0,0,-1,-1,-1,-2,-2,-3,-3,-3,-4,-4,-4,-5,-5,-5
    FCB     -6,-6,-6,-7,-7,-7,-8,-8,-8,-9,-9,-9,-10,-10,-10,-10
    FCB     -11,-11,-11,-11,-12,-12,-12,-12,-12,-13,-13,-13,-13,-13,-14,-14
    FCB     -14,-14,-14,-14,-14,-14,-15,-15,-15,-15,-15,-15,-15,-15,-15,-15
    FCB     -15,-15,-15,-15,-15,-15,-15,-15,-15,-15,-15,-14,-14,-14,-14,-14
    FCB     -14,-14,-14,-13,-13,-13,-13,-13,-12,-12,-12,-12,-12,-11,-11,-11
    FCB     -11,-10,-10,-10,-10,-9,-9,-9,-8,-8,-8,-7,-7,-7,-6,-6
    FCB     -6,-5,-5,-5,-4,-4,-4,-3,-3,-3,-2,-2,-1,-1,-1,0
; formant 3, amplitude 8
TabF3:
    FCB     0,0,0,1,1,1,1,1,2,2,2,2,2,3,3,3
    FCB     3,3,3,4,4,4,4,4,4,5,5,5,5,5,5,6
    FCB     6,6,6,6,6,6,6,7,7,7,7,7,7,7,7,7
    FCB     7,7,8,8,8,8,8,8,8,8,8,8,8,8,8,8
    FCB     8,8,8,8,8,8,8,8,8,8,8,8,8,8,8,7
    FCB     7,7,7,7,7,7,7,7,7,7,6,6,6,6,6,6
    FCB     6,6,5,5,5,5,5,5,4,4,4,4,4,4,3,3
    FCB     3,3,3,3,2,2,2,2,2,1,1,1,1,1,0,0
    FCB     0,0,0,-1,-1,-1,-1,-1,-2,-2,-2,-2,-2,-3,-3,-3
    FCB     -3,-3,-3,-4,-4,-4,-4,-4,-4,-5,-5,-5,-5,-5,-5,-6
    FCB     -6,-6,-6,-6,-6,-6,-6,-7,-7,-7,-7,-7,-7,-7,-7,-7
    FCB     -7,-7,-8,-8,-8,-8,-8,-8,-8,-8,-8,-8,-8,-8,-8,-8
    FCB     -8,-8,-8,-8,-8,-8,-8,-8,-8,-8,-8,-8,-8,-8,-8,-7
    FCB     -7,-7,-7,-7,-7,-7,-7,-7,-7,-7,-6,-6,-6,-6,-6,-6
    FCB     -6,-6,-5,-5,-5,-5,-5,-5,-4,-4,-4,-4,-4,-4,-3,-3
    FCB     -3,-3,-3,-3,-2,-2,-2,-2,-2,-1,-1,-1,-1,-1,0,0
; voyelles françaises : incréments de phase de F1, F2, F3 (f x 65536 / 7200.0 Hz)
Voyelles:
    FDB     6827,11833,22756          ; A  750 / 1300 / 2500 Hz
    FDB     3641,19115,24576          ; E  400 / 2100 / 2700 Hz
    FDB     2549,20480,26396          ; I  280 / 2250 / 2900 Hz
    FDB     4096,7737,22756          ; O  450 / 850 / 2500 Hz
    FDB     2731,6827,20935          ; OU 300 / 750 / 2300 Hz
    FDB     2549,16384,20025          ; U  280 / 1800 / 2200 Hz
    FDB     0
INC_440         equ 4005
INC_100         equ 910
INC_3000        equ 27307
PITCH_N         equ 65          ; échantillons par période de voix (110 Hz)

; --- Variables ---
Choix           rmb 1
Seed            rmb 2
Count           rmb 2
Sample          rmb 2           ; prochain échantillon (MSB toujours 0)
Ph1             rmb 2
Ph2             rmb 2
Ph3             rmb 2
In1             rmb 2
In2             rmb 2
In3             rmb 2
PitchC          rmb 1
Acc             rmb 1

; Les services d'affichage (lib/vis.inc) : l'application tourne dans sa
; propre page et emporte sa copie (OSM-VISION, en page 0, ne se voit pas).
    include "../lib/vision.asm"
