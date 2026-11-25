; ===================================================================
; OSM3D.ASM - Annonay en 3D (lancer de rayons), à pied
; ===================================================================
; Flèches haut/bas : avancer/reculer ; gauche/droite : tourner ; Echap :
; quitter. Application d'OSM-VISION (page 1, liée à $0000, App_Start à
; l'offset 0), plein écran 80 x 30, carte OSM39_mono. La carte est
; OSM3D.MAP (celle d'OSM City refaite pour la 3D : rues plus larges,
; trottoirs, bâti lissé ; chargée en pages 2-3) ; les rues OSM3D.RUE (en
; page 1, RUES_ADR).
;
; SOURCE UNIQUE : tools/osm3d/osm3d.py (les tables, le fichier des rues,
; et le modèle exact de l'écran que test/verifie_osm3d.py compare à ce
; binaire). apps/osm3d_data.inc, OSM3D.MAP et OSM3D.RUE sont GÉNÉRÉS. Carte :
; © contributeurs OpenStreetMap (ODbL).
;
; RENDU. Un rayon par colonne de la vue (64 x 18 cellules, mosaïques 2 x 3
; de la page 1), DDA case par case dans l'anneau de la carte ; chaque case
; traversée peint son sol, le premier bâti est un mur ; Col54 reçoit les
; 54 couleurs de la colonne, Composer en fait 18 cellules (deux couleurs
; chacune). Voir l'en-tête de osm3d.py.
;
; CARTE. 512 x 255 cases de 4 bits, rangée y = 256 octets en page 2 +
; y/128. Le jeu en garde 32 rangées (y - 16 .. y + 15) dans un anneau en
; page 1 (rangée y en CACHE + 256 (y mod 32)) : un pas vers le nord ou le
; sud en recopie une par FarRead (juste après une trame : FarRead masque
; les IRQ). La mini-carte lit ses 48 rangées en pages 2-3 (28 octets).
;
; ÉCRAN. Toute écriture en VRAM passe par une file de copies (Jobs : source,
; destination, longueur) que l'IRQ du VSYNC (Irq_3D, posée dans rvec_IRQ
; avant celle du BIOS) vide au début du retour de trame, dans un BUDGET
; par trame (octets + COUT_COPIE par copie ; TFM). La vue : deux tampons (Want calculé, Pret recopié,
; échangés quand la file est vide, seules les rangées changées partent) ;
; la mini-carte (MiniBuf) et les rangées de texte (TxtBuf) ne changent que
; file vide. Les rangées 25-29 d'OSM-VISION sont gardées (SaveBas) et
; rendues par la même file.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

    export App_Start

CACHE           equ $4000           ; 32 rangées de 256 octets ($4000-$5FFF)
CACHE_HI        equ $40
RUES_ADR        equ $6000           ; OSM3D.RUE (8 Ko au plus)
; tampons (le code doit finir avant TAMPONS : apps/Makefile le vérifie)
TAMPONS         equ $2600
BufA            equ TAMPONS         ; vue : 18 rangées de 128 octets
BufB            equ BufA+$900
MiniBuf         equ BufB+$900       ; colonnes 64-79 : 18 rangées de 32 octets
TxtBuf          equ MiniBuf+$240    ; rangées 18-21 : 4 x 160 octets
SaveBas         equ TxtBuf+$280     ; rangées 25-29 d'OSM-VISION : 800 octets
FIN_TAMPONS     equ SaveBas+$320
RANG_O          equ 128             ; octets par rangée de vue
BUDGET          equ 580             ; coût des copies par trame au plus :
COUT_COPIE      equ 34              ; octets + COUT_COPIE par copie (~3 cycles
                                    ; l'unité : ~1750 cycles)
JOBS_N          equ 64
VITESSE         equ 10              ; 1/256 de colonne par trame
ROTATION        equ 16              ; 16/1024 de tour (5,6°) par appui
TOURNE_MAX      equ 8               ; pas en attente au plus
MARGE_X         equ 64              ; on reste à ~0,6 m du bâti
MARGE_Y         equ 26
TRAMES_MAX      equ 8
VIDE_ATTR       equ $08

    section .code

; -------------------------------------------------------------------
; Point d'entrée (offset 0). IRQ actives à l'entrée.
; -------------------------------------------------------------------
App_Start:
    ANDCC   #%11101111
    LDX     #NomCarte               ; la carte, en pages 2-3
    LDY     #NomFmt
    JSR     [table_function_ram+sys_Format_Filename_83]
    LDX     #NomFmt
    LDA     #2
    LDY     #0
    JSR     [table_function_ram+sys_FS_LoadFile]
    BCC     AS_Carte
    RTS                             ; pas de carte : rien
AS_Carte:
    LDX     #NomRues                ; les rues, en page 1 à RUES_ADR
    LDY     #NomFmt
    JSR     [table_function_ram+sys_Format_Filename_83]
    LDX     #NomFmt
    LDA     #1
    LDY     #RUES_ADR
    JSR     [table_function_ram+sys_FS_LoadFile]
    BCC     AS_Rues
    RTS
AS_Rues:
    LDD     DepartX
    STD     PosX
    LDD     DepartY
    STD     PosY
    LDA     #128
    STA     FrX
    STA     FrY
    LDD     DepartA
    STD     Ang
    CLR     Niv                     ; au sol
    CLR     KeyHaut
    CLR     KeyBas
    CLR     KeyGauche
    CLR     KeyDroite
    CLR     Tourne
    CLR     KbE0
    CLR     KbRel
    CLR     QuitReq
    CLR     EscUp
    CLR     JqT
    CLR     JqQ
    LDD     #$FFFF                  ; la mini-carte et la plaque : à faire
    STD     MiniX
    CLR     PlqNum
    LDA     #$FF
    STA     PlqNum
    LDD     PosY                    ; les 32 rangées autour du départ
    SUBD    #16
    STD     Ligne
    LDA     #32
    STA     Compte
AS_Cache:
    LDD     Ligne
    JSR     Charge_Rangee
    LDD     Ligne
    ADDD    #1
    STD     Ligne
    DEC     Compte
    BNE     AS_Cache
    JSR     Init_Tampons
    LDA     >kbd_tete               ; ce qui était tapé avant : oublié
    STA     >kbd_queue
    ORCC    #%00010000              ; la file de copies se branche sur l'IRQ
    LDX     >rvec_IRQ
    STX     AncienIRQ
    LDX     #Irq_3D
    STX     >rvec_IRQ
    ANDCC   #%11101111
    LDX     #VRAM_BASE+(25*VRAM_LIGNE)  ; garder les rangées 25-29
    LDY     #SaveBas
    LDB     #5
AS_Garde:
    PSHS    B,X,Y
    LDD     #VRAM_LIGNE
    JSR     Ajoute
    PULS    B,X,Y
    LEAX    VRAM_LIGNE,X
    LEAY    VRAM_LIGNE,Y
    DECB
    BNE     AS_Garde
    LDX     #TxtBuf                 ; rangées 18-21 : le texte
    LDY     #VRAM_BASE+(18*VRAM_LIGNE)
    LDB     #4
AS_Texte:
    PSHS    B,X,Y
    LDD     #VRAM_LIGNE
    JSR     Ajoute
    PULS    B,X,Y
    LEAX    VRAM_LIGNE,X
    LEAY    VRAM_LIGNE,Y
    DECB
    BNE     AS_Texte
    LDY     #VRAM_BASE+(22*VRAM_LIGNE)  ; rangées 22-29 : vides (la 21)
    LDB     #8
AS_Vide:
    PSHS    B,Y
    LDX     #TxtBuf+(3*VRAM_LIGNE)
    LDD     #VRAM_LIGNE
    JSR     Ajoute
    PULS    B,Y
    LEAY    VRAM_LIGNE,Y
    DECB
    BNE     AS_Vide
    LDX     #MiniBuf                ; le cadre de la mini-carte (rangées 0, 17)
    LDY     #VRAM_BASE+(64*2)
    LDD     #32
    JSR     Ajoute
    LDX     #MiniBuf+(17*32)
    LDY     #VRAM_BASE+(17*VRAM_LIGNE)+(64*2)
    LDD     #32
    JSR     Ajoute
    LDD     >vsync_tick
    STD     TickImage
    LDA     #1
    STA     Trames

; -------------------------------------------------------------------
; Boucle : une image par tour
; -------------------------------------------------------------------
Boucle:
    TST     QuitReq
    LBNE    Quitter
    JSR     Bouger
    JSR     Rendre                  ; dans Want, pendant que l'IRQ recopie
Bo_Attente:                         ; la file vide ?
    LDA     JqQ
    CMPA    JqT
    BNE     Bo_Attente
    JSR     Marquer                 ; échange, les rangées changées partent
    JSR     Mini_Si
    JSR     Plaque_Si
    LDD     >vsync_tick             ; trames entre deux images
    SUBD    TickImage
    BNE     Bo_PasZero
    LDB     #1
Bo_PasZero:
    CMPD    #TRAMES_MAX
    BLS     Bo_Trames
    LDB     #TRAMES_MAX
Bo_Trames:
    STB     Trames
    LDD     >vsync_tick
    STD     TickImage
    BRA     Boucle

; Sortie : les rangées 25-29 rendues (par la file), le relâchement d'Echap
; attendu (une demi-seconde au plus), l'IRQ du BIOS seule, la file du
; clavier vidée pour OSM-VISION (qui rend les rangées 0-24).
Quitter:
    LDA     JqQ
    CMPA    JqT
    BNE     Quitter
    LDX     #SaveBas
    LDY     #VRAM_BASE+(25*VRAM_LIGNE)
    LDB     #5
Q_Rend:
    PSHS    B,X,Y
    LDD     #VRAM_LIGNE
    JSR     Ajoute
    PULS    B,X,Y
    LEAX    VRAM_LIGNE,X
    LEAY    VRAM_LIGNE,Y
    DECB
    BNE     Q_Rend
Q_File:
    LDA     JqQ
    CMPA    JqT
    BNE     Q_File
    LDB     #30
Q_Attente:
    TST     EscUp
    BNE     Q_Fin
    PSHS    B
    JSR     Attendre_Trame
    PULS    B
    DECB
    BNE     Q_Attente
Q_Fin:
    ORCC    #%00010000
    LDX     AncienIRQ
    STX     >rvec_IRQ
    LDA     >kbd_tete
    STA     >kbd_queue
    CLR     >kbd_apres_f0
    CLR     >kbd_echap
    ANDCC   #%11101111
    RTS

; -------------------------------------------------------------------
; La file de copies. Ajoute : X = source, Y = destination, D = longueur
; (au plus BUDGET - COUT_COPIE). Détruit D, U.
; -------------------------------------------------------------------
Ajoute:
    PSHS    D
    LDB     JqT
    LDA     #6
    MUL
    ADDD    #Jobs
    TFR     D,U
    STX     ,U
    STY     2,U
    PULS    D
    STD     4,U
    LDA     JqT                     ; la copie est écrite : elle compte
    INCA
    ANDA    #JOBS_N-1
    STA     JqT
    RTS

; Irq_3D : posée dans rvec_IRQ. Au tout début du retour de trame, les
; copies de la file tant que leur coût (octets + COUT_COPIE chacune) ne
; dépasse pas BUDGET, puis l'IRQ du BIOS. Tous les registres sont dans la
; trame d'interruption.
Irq_3D:
    LDD     #BUDGET
    STD     Reste
Iq_Job:
    LDB     JqQ
    CMPB    JqT
    BEQ     Iq_Bios
    LDA     #6
    MUL
    ADDD    #Jobs
    TFR     D,U
    LDD     Reste
    SUBD    4,U
    BLO     Iq_Bios                 ; (pas assez pour celle-ci : la suivante trame)
    SUBD    #COUT_COPIE
    BLO     Iq_Bios
    STD     Reste
    LDD     4,U
    TFR     D,W
    LDX     ,U
    LDY     2,U
    TFM     X+,Y+
    LDA     JqQ
    INCA
    ANDA    #JOBS_N-1
    STA     JqQ
    BRA     Iq_Job
Iq_Bios:
    JSR     Lire_Clavier            ; à chaque trame : la file de la NMI (16
                                    ; octets) ne déborde jamais
    JMP     [AncienIRQ]

; -------------------------------------------------------------------
; Clavier : octets PS/2 de la file de la NMI, lus par Irq_3D à chaque
; trame (lus seulement entre deux images, la répétition automatique d'une
; flèche tenue remplissait la file pendant le calcul et le relâchement
; se perdait : la touche restait tenue). Haut/Bas : tenues. Gauche/Droite :
; chaque code d'appui (l'appui, puis chaque répétition du clavier) compte
; un pas de ROTATION dans Tourne, que Bouger consomme. (Une rotation tant
; que la flèche est TENUE a été essayée le 22 nov. : sur la machine, un
; appui bref tournait sans fin, le relâchement n'étant pas vu.)
; -------------------------------------------------------------------
Lire_Clavier:
    LDB     >kbd_queue
    CMPB    >kbd_tete
    LBEQ    LC_Fin
    LDX     #kbd_buf
    LDA     B,X
    INCB
    ANDB    #15
    STB     >kbd_queue
    CMPA    #$E0
    BNE     LC_PasE0
    STA     KbE0
    BRA     Lire_Clavier
LC_PasE0:
    CMPA    #$F0
    BNE     LC_Code
    STA     KbRel
    BRA     Lire_Clavier
LC_Code:
    LDB     KbRel                   ; B <> 0 : relâchement
    LDX     #0
    TST     KbE0
    BEQ     LC_Echap
    CMPA    #$75                    ; E0 75 : haut
    BNE     LC_E1
    LDX     #KeyHaut
LC_E1:
    CMPA    #$72                    ; E0 72 : bas
    BNE     LC_E2
    LDX     #KeyBas
LC_E2:
    CMPA    #$6B                    ; E0 6B : gauche
    BNE     LC_E3
    LDX     #KeyGauche
LC_E3:
    CMPA    #$74                    ; E0 74 : droite
    BNE     LC_Tenue
    LDX     #KeyDroite
LC_Tenue:
    CMPX    #0
    BEQ     LC_Suite
    TSTB
    BEQ     LC_Appui
    CLR     ,X
    BRA     LC_Suite
LC_Appui:
    LDA     #1
    STA     ,X
    CMPX    #KeyGauche              ; chaque code d'appui (et chaque
    BNE     LC_PasG                 ; répétition du clavier) : un pas
    BSR     Pas_G
    BRA     LC_Suite
LC_PasG:
    CMPX    #KeyDroite
    BNE     LC_Suite
    BSR     Pas_D
    BRA     LC_Suite
LC_Echap:
    CMPA    #$76                    ; Echap
    BNE     LC_Suite
    TSTB
    BEQ     LC_EchapAppui
    LDA     #1
    STA     EscUp
    BRA     LC_Suite
LC_EchapAppui:
    LDA     #1
    STA     QuitReq
LC_Suite:
    CLR     KbE0
    CLR     KbRel
    LBRA    Lire_Clavier
LC_Fin:
    RTS

; Un pas de rotation en attente (Tourne, TOURNE_MAX au plus). Détruit A.
Pas_G:
    LDA     Tourne
    CMPA    #-TOURNE_MAX
    BLE     PG_Fin
    DECA
    STA     Tourne
PG_Fin:
    RTS
Pas_D:
    LDA     Tourne
    CMPA    #TOURNE_MAX
    BGE     PD_Fin
    INCA
    STA     Tourne
PD_Fin:
    RTS

; Attend le prochain VSYNC en lisant le clavier.
Attendre_Trame:
    LDD     >vsync_tick
    STD     TickVu
AT_Boucle:
    LDD     >vsync_tick
    CMPD    TickVu
    BEQ     AT_Boucle
    RTS

; -------------------------------------------------------------------
; Déplacement : Trames trames depuis la dernière image. Position = la
; case (16 bits) et la fraction (8 bits) : un nombre de 24 bits.
; -------------------------------------------------------------------
Bouger:
    PSHS    CC                      ; tourner : les appuis comptés par l'IRQ
    ORCC    #%00010000
    LDB     Tourne
    CLR     Tourne
    PULS    CC
    SEX                             ; Ang += Tourne x ROTATION (16)
    LSLD
    LSLD
    LSLD
    LSLD
    ADDD    Ang
    ANDA    #3
    STD     Ang
    LDB     Trames                  ; avancer : VITESSE x trames (1/256)
    LDA     #VITESSE
    MUL
    STD     Pas
    TST     KeyHaut
    BNE     Bg_Avance
    TST     KeyBas
    LBEQ    Bg_Fin
    LDD     #0                      ; reculer : pas négatif
    SUBD    Pas
    STD     Pas
Bg_Avance:
    LDD     Ang                     ; dx = cos x pas (colonnes)
    ADDD    #256
    JSR     Sin_D
    MULD    Pas
    STQ     Tmp4
    LDD     Tmp4+1
    STD     DepX
    LDD     Ang                     ; dy = sin x pas x 107 / 256 (rangées)
    JSR     Sin_D
    MULD    Pas
    STQ     Tmp4
    LDD     Tmp4+1
    MULD    C107
    STQ     Tmp4
    LDD     Tmp4+1
    STD     DepY
    LDX     #PosX                   ; en x
    LDD     DepX
    LDY     #MARGE_X
    LBSR    Bg_Nouv
    LDX     NouvC                   ; la case, la rangée inchangée
    LDY     PosY
    JSR     Passe
    BCS     Bg_Y
    LDX     NouvP                   ; une autre case : l'étage d'arrivée
    CMPX    PosX
    BEQ     Bg_XMeme
    LDY     PosY
    JSR     Passe
    BCS     Bg_XMeme
    STA     Niv
Bg_XMeme:
    LDD     NouvP
    STD     PosX
    LDA     NouvP+2
    STA     FrX
Bg_Y:
    LDX     #PosY                   ; en y
    LDD     DepY
    LDY     #MARGE_Y
    LBSR    Bg_Nouv
    LDX     PosX
    LDY     NouvC
    JSR     Passe
    BCS     Bg_Fin
    LDX     PosX                    ; une autre case : l'étage d'arrivée
    LDY     NouvP
    CMPY    PosY
    BEQ     Bg_YMeme
    JSR     Passe
    BCS     Bg_YMeme
    STA     Niv
Bg_YMeme:
    LDD     PosY
    STD     AncY
    LDD     NouvP
    STD     PosY
    LDA     NouvP+2
    STA     FrY
    LDD     PosY                    ; une rangée de plus dans l'anneau ?
    CMPD    AncY
    BEQ     Bg_Fin
    BGT     Bg_Sud
    SUBD    #16                     ; vers le nord : y - 16
    BRA     Bg_Charge
Bg_Sud:
    ADDD    #15                     ; vers le sud : y + 15
Bg_Charge:
    STD     Ligne
    JSR     Attendre_Trame          ; FarRead masque les IRQ : juste après une
    LDD     Ligne                   ; trame
    JMP     Charge_Rangee
Bg_Fin:
    RTS

; Bg_Nouv : X = la position (case 16 bits, fraction 8 bits : 3 octets),
; D = le déplacement (1/256, signé), Y = la marge -> NouvP (3 octets) =
; position + déplacement ; NouvC = la case de NouvP +/- la marge (du côté
; du déplacement).
Bg_Nouv:
    STD     Dep
    STY     Marge
    CLR     Signe
    TSTA
    BPL     BN_Pos
    COM     Signe
BN_Pos:
    LDD     1,X                     ; les deux octets bas
    ADDD    Dep
    STD     NouvP+1
    LDA     ,X
    ADCA    Signe
    STA     NouvP
    LDD     Marge                   ; +/- la marge
    TST     Signe
    BEQ     BN_Marge
    LDD     #0
    SUBD    Marge
BN_Marge:
    STD     Dep
    CLR     Signe
    TSTA
    BPL     BN_Pos2
    COM     Signe
BN_Pos2:
    LDD     NouvP+1
    ADDD    Dep
    STB     Tmp4                    ; (la fraction : inutile)
    LDB     NouvP
    ADCB    Signe
    EXG     A,B                     ; D = la case (B : poids faible)
    STD     NouvC
    RTS

; Passe : X = mx, Y = my (la case visée), depuis la case (PosX, PosY) à
; l'étage Niv -> C = 1 si on ne peut pas y aller (bâti, eau, falaise,
; muret, hors de la carte, ou l'étage), sinon A = l'étage d'arrivée
; (osm3d.py, passe) : sur un tablier (pont, tablier, passage, culée, pied
; d'arche) on arrive d'un tablier (étage 1) ou d'une rampe (on monte) ; au
; sol, seul le passage (SOUS_PONT, SOUS_ARC) se traverse ; du tablier on
; ne descend que sur une rampe. Garde X, Y.
Passe:
    JSR     SorteC
    CMPB    #S_BATI
    BEQ     Pa_Non
    CMPB    #S_EAU
    BEQ     Pa_Non
    CMPB    #S_FALAISE
    BEQ     Pa_Non
    CMPB    #S_MURET
    BEQ     Pa_Non
    CMPB    #S_PONT
    BEQ     Pa_Tab
    CMPB    #S_TABLIER
    BEQ     Pa_Tab
    CMPB    #S_SOUS_PONT
    BEQ     Pa_Tab
    CMPB    #S_CULEE
    BEQ     Pa_Tab
    CMPB    #S_PONT_ARC
    BEQ     Pa_Tab
    CMPB    #S_SOUS_ARC
    BEQ     Pa_Tab
    TST     Niv                     ; pas un tablier : du pont, seule une
    BEQ     Pa_Sol                  ; rampe
    CMPB    #S_RAMPE
    BNE     Pa_Non
Pa_Sol:
    CLRA
    ANDCC   #$FE
    RTS
Pa_Tab:
    TST     Niv
    BNE     Pa_Un
    PSHS    B,X,Y                   ; d'une rampe : on monte
    LDX     PosX
    LDY     PosY
    JSR     SorteC
    CMPB    #S_RAMPE
    PULS    B,X,Y
    BEQ     Pa_Un
    CMPB    #S_SOUS_PONT            ; au sol : dessous
    BEQ     Pa_Sol
    CMPB    #S_SOUS_ARC
    BEQ     Pa_Sol
Pa_Non:
    ORCC    #1
    RTS
Pa_Un:
    LDA     #1
    ANDCC   #$FE
    RTS

; Sin_D : D = angle (0-1023, ou plus : masqué) -> D = sin x 256 (signé).
; SinQ : le quart de tour (257 mots).
Sin_D:
    ANDA    #3
    STA     SinK                    ; le quart de tour ; B = q
    BITA    #1
    BEQ     SD_Q
    CLRA                            ; quarts 1 et 3 : 256 - q
    NEGB
    BNE     SD_Idx
    INCA                            ; (q = 0 : 256)
    BRA     SD_Idx
SD_Q:
    CLRA
SD_Idx:
    LSLB
    ROLA
    LDX     #SinQ
    LDD     D,X
    PSHS    A                       ; quarts 2 et 3 : négatif
    LDA     SinK
    CMPA    #2
    PULS    A
    BLO     SD_Fin
    COMA
    COMB
    ADDD    #1
SD_Fin:
    RTS

; Delta_D : D = angle (0-1023) -> D = 1 / |cos| en 8.8 (DeltaQ, plié).
Delta_D:
    ANDA    #1                      ; q = angle & 511
    CMPD    #256
    BLS     DD_Q
    PSHS    D                       ; q > 256 : 512 - q
    LDD     #512
    SUBD    ,S++
DD_Q:
    LSLB
    ROLA
    LDX     #DeltaQ
    LDD     D,X
    RTS

; -------------------------------------------------------------------
; Charge_Rangee : D = y (16 bits signés) -> la rangée y de la carte dans
; l'anneau (CACHE + 256 (y mod 32)) ; hors de la carte : du bâti.
; Détruit D, X, Y, U, W. (comme OSM City)
; -------------------------------------------------------------------
Charge_Rangee:
    STD     CrY
    ANDB    #31
    TFR     B,A
    CLRB
    ADDD    #CACHE
    TFR     D,Y
    LDD     CrY
    CMPD    #CARTE_H                ; (négatif : très grand, non signé)
    BHS     CR_Hors
    TFR     B,A                     ; source : 256 (y mod 128) ...
    ANDA    #127
    CLRB
    TFR     D,X
    LDA     CrY+1                   ; ... en page 2 + y / 128
    LSLA
    LDA     #2
    ADCA    #0
    LDB     #1
    LDU     #256
    JSR     [table_function_ram+sys_FarRead]
    RTS
CR_Hors:
    LDA     #(S_BATI*16)+S_BATI
    STA     ,Y
    LEAX    ,Y
    LEAY    1,Y
    LDW     #255
    TFM     X+,Y+
    RTS

; SorteC : X = mx, Y = my -> B = la sorte (du bâti hors de la carte), lue
; dans l'anneau. Préserve X, Y, U. Détruit A, W.
SorteC:
    CMPX    #CARTE_L
    BHS     SC_Hors
    CMPY    #CARTE_H
    BHS     SC_Hors
    PSHS    U
    TFR     Y,W
    TFR     X,D
    LSRA
    RORB
    TFR     F,A
    ANDA    #31
    ORA     #CACHE_HI
    TFR     D,U
    LDB     ,U
    BCS     SC_Bas
    LSRB
    LSRB
    LSRB
    LSRB
    PULS    U,PC
SC_Bas:
    ANDB    #$0F
    PULS    U,PC
SC_Hors:
    LDB     #S_BATI
    RTS

; -------------------------------------------------------------------
; Rendu : un rayon par colonne (Col54), puis ses 18 cellules dans Want
; -------------------------------------------------------------------
Rendre:
    LDD     #(DESSOUS*256)+MUR_P    ; au sol : les tabliers en bande, les
    TST     Niv                     ; culées et remblais en murs
    BEQ     Re_Masq
    CLRD
Re_Masq:
    STA     MasqD
    STB     MasqM
    CLR     Col
Re_Colonne:
    JSR     Rayon
    JSR     Composer
    INC     Col
    LDA     Col
    CMPA    #VUE_L
    BLO     Re_Colonne
    RTS

; Rayon : colonne Col -> Col54 (osm3d.py, rayon). Le sol n'est peint
; qu'aux changements de couleur (des peintures successives de la même
; couleur se fondent : même résultat) ; la case lue par RowPtr (la rangée
; de l'anneau) ; l'indice des hauteurs = le mot haut de d x ColCos16.
Rayon:
    LDB     Col                     ; r = (Ang + ColOff[Col]) & 1023
    LSLB
    LDX     #ColOff
    ABX
    LDD     ,X
    ADDD    Ang
    ANDA    #3
    STD     RayA
    JSR     Delta_D                 ; dX = Delta(r)
    STD     DltX
    LDD     RayA                    ; dY = Delta(r - 256) x RY / 256, plafonné
    SUBD    #256
    ANDA    #3
    JSR     Delta_D
    MULD    Ry614
    STQ     Tmp4
    LDA     Tmp4                    ; > 32767 : DELTA_MAX
    BNE     Ra_DyMax
    LDD     Tmp4+1
    BPL     Ra_DyOk
Ra_DyMax:
    LDD     #DELTA_MAX
Ra_DyOk:
    STD     DltY
    LDB     Col
    LSLB
    LDX     #ColCos16
    ABX
    LDD     ,X
    STD     CosR
    LDD     RayA                    ; sens en x : +1 si r <= 256 ou r >= 768
    CMPD    #256
    BLS     Ra_XPlus
    CMPD    #768
    BHS     Ra_XPlus
    LDD     #-1
    STD     PasX
    CLRA
    LDB     FrX
    BRA     Ra_XSide
Ra_XPlus:
    LDD     #1
    STD     PasX
    LDD     #256
    SUBB    FrX
    SBCA    #0
Ra_XSide:
    MULD    DltX
    STQ     Tmp4
    LDD     Tmp4+1
    STD     SideX
    LDD     RayA                    ; sens en y : +1 si r <= 512
    CMPD    #512
    BLS     Ra_YPlus
    LDD     #-1
    STD     PasY
    CLRA
    LDB     FrY
    BRA     Ra_YSide
Ra_YPlus:
    LDD     #1
    STD     PasY
    LDD     #256
    SUBB    FrY
    SBCA    #0
Ra_YSide:
    MULD    DltY
    STQ     Tmp4
    LDD     Tmp4+1
    STD     SideY
    LDA     #CIEL                   ; le ciel, puis du noir sous l'horizon
    STA     PCoul
    LDX     #PCoul
    LDY     #Col54
    LDW     #HORIZON
    TFM     X,Y+
    CLR     PCoul
    LDX     #PCoul
    LDW     #SOUS-HORIZON
    TFM     X,Y+
    CLR     PCoul                   ; les marques : l'horizon, la fin
    LDX     #PCoul
    LDY     #Mark
    LDW     #VUE_H
    TFM     X,Y+
    LDA     #2
    STA     Mark+(HORIZON/3)
    LDA     #$FF
    STA     Mark+VUE_H
    LDA     #SOUS
    STA     BasC
    LDD     PosX
    STD     RX
    LDA     #16                     ; pas en y permis : 15 vers le sud, 16
    LDB     PasY+1                  ; vers le nord (osm3d.py : l'anneau)
    BPL     Ra_NY
    INCA
Ra_NY:
    STA     NYr
    LDA     PosY+1                  ; la case : CellP = (rangée de l'anneau,
    ANDA    #31                     ; x / 2) ; le quartet : x impair = bas
    ORA     #CACHE_HI
    LDB     PosX
    STB     Tmp4
    LDB     PosX+1
    LSR     Tmp4
    RORB
    STD     CellP
    LDX     PosX                    ; la couleur du sol de départ
    LDY     PosY
    JSR     SorteC
    LDX     #SolB
    LDA     B,X
    STA     CurC
    CLR     BandeF
    LDD     #1                      ; déjà sous un tablier : depuis l'œil
    STD     DIn
Ra_Tables:
    LDU     #SolHi+128              ; (couleur du quartet haut, bas : l'octet
    LDY     #SolLo+128              ;  est l'indice signé B,U / B,Y)
Ra_Pas:
    LDD     SideX
    CMPD    SideY
    BHS     Ra_PasY
    CMPD    #DMAX                   ; trop loin : fin
    LBHS    Ra_FinSol
    ADDD    DltX                    ; vers la case suivante en x (d < DMAX,
    STD     SideX                   ; delta <= 32767 : jamais au-delà de $FFFF)
    LDD     RX
    ADDD    PasX
    STD     RX
    CMPD    #CARTE_L                ; hors de la carte : du bâti
    BHS     Ra_Hors
    LSRA                            ; B = x / 2, C = x impair
    RORB
    STB     CellP+1                 ; (STB, LDB : C gardé)
    LDB     [CellP]
    BCS     Ra_XBas
    LDA     B,U
    CMPA    CurC
    BEQ     Ra_Pas
    BRA     Ra_ChX
Ra_XBas:
    LDA     B,Y
    CMPA    CurC
    BEQ     Ra_Pas
    BRA     Ra_ChX
Ra_Hors:
    LDA     #$FF
Ra_ChX:
    CLR     Cote
    PSHS    A
    LDD     SideX                   ; la distance : avant le pas
    SUBD    DltX
    BRA     Ra_Change
Ra_PasY:
    LDD     SideY
    CMPD    #DMAX
    LBHS    Ra_FinSol
    ADDD    DltY                    ; vers la case suivante en y
    STD     SideY
    DEC     NYr                     ; hors des rangées de l'anneau : fin
    LBEQ    Ra_FinSol
    LDA     CellP                   ; la rangée suivante de l'anneau (x
    ADDA    PasY+1                  ; reste dans la carte : sinon, le bâti
    ANDA    #31                     ; aurait arrêté le rayon)
    ORA     #CACHE_HI
    STA     CellP
    LDB     [CellP]
    LDA     RX+1                    ; C = x impair
    LSRA
    BCS     Ra_YBas
    LDA     B,U
    CMPA    CurC
    LBEQ    Ra_Pas
    BRA     Ra_ChY
Ra_YBas:
    LDA     B,Y
    CMPA    CurC
    LBEQ    Ra_Pas
Ra_ChY:
    LDB     #8
    STB     Cote
    PSHS    A
    LDD     SideY
    SUBD    DltY
Ra_Change:                          ; D = la distance, (S) = la nouvelle
    STD     RayD                    ; couleur, $FF : bâti
    PULS    A
    STA     NewC
    LDD     RayD                    ; i = (d x ColCos x 16) / 65536, au moins 1
    MULD    CosR
    CMPD    #0
    BNE     Ra_I
    LDD     #1
Ra_I:
    STD     Idx
    LDX     #Bas                    ; le sol d'avant, jusqu'au pied
    LDA     D,X
    ADDA    #HORIZON
    CMPA    BasC
    BHS     Ra_C2
    LDB     BasC
    STA     BasC
    PSHS    A
    LDA     CurC
    ANDA    #15
    STA     PCoul
    PULS    A
    JSR     Peint
Ra_C2:
    LDA     NewC
    CMPA    #$FF
    BEQ     Ra_Mur
    LDA     CurC                    ; sous un tablier jusqu'ici ?
    BITA    MasqD
    BEQ     Rc_Pas
    LDA     NewC
    BITA    MasqD
    BNE     Ra_C3                   ; encore dessous (CurC : la dernière case)
    LDD     Idx                     ; sort : la bande
    JSR     Bande
    BRA     Rc_Autre
Rc_Pas:
    LDA     NewC
    BITA    MasqD
    BEQ     Rc_Autre
    LDD     Idx                     ; entre
    STD     DIn
    BRA     Ra_C3
Rc_Autre:
    LDA     NewC                    ; une culée, un remblai (au sol) ?
    BITA    MasqM
    BEQ     Rc_Muret
    JSR     Mur_Pont
    BRA     Ra_C3
Rc_Muret:
    LDA     NewC                    ; un muret ?
    BITA    #MURET_F
    BEQ     Ra_C3
    JSR     Muret
Ra_C3:
    LDA     NewC
    STA     CurC
    LBRA    Ra_Tables
Ra_Mur:
    LDA     CurC                    ; un mur sous un tablier : la bande d'abord
    BITA    MasqD
    BEQ     Ra_Mur2
    LDD     Idx
    JSR     Bande
Ra_Mur2:
    LDA     RX+1                    ; le mur : Facades[((x/8) + 3 (y/4)) & 3]
    LSRA
    LSRA
    LSRA
    ANDA    #3
    STA     Tmp4
    LDA     CellP                   ; (y mod 32 : ses bits 2-3 suffisent)
    LSRA
    LSRA
    ANDA    #3
    TFR     A,B
    ASLA
    PSHS    B
    ADDA    ,S+
    ADDA    Tmp4
    ANDA    #3
    LDX     #Facades
    LDA     A,X
    STA     PCoul
    LDX     #Haut
    LDD     Idx
    LDA     D,X
    NEGA
    ADDA    #HORIZON
    LDB     BasC
    TST     Cote                    ; à l'ombre (face en x), x pair : des
    BEQ     Ra_Plein                ; fenêtres
    PSHS    A
    LDA     RX+1
    LSRA
    PULS    A
    LBCC    Fenetres
Ra_Plein:
    TST     BandeF                  ; une bande : le mur ne peint que le ciel
    LBNE    PeintC
    JMP     Peint
Ra_FinSol:
    LDA     CurC                    ; fini sous un tablier : la bande jusqu'au
    BITA    MasqD                   ; plus loin
    BEQ     Ra_FS2
    LDD     #NIDX-1
    JSR     Bande
Ra_FS2:
    LDA     CurC                    ; le reste du sol : la couleur en cours
    ANDA    #15
    STA     PCoul
    LDA     #HORIZON
    LDB     BasC
    ; (continue dans Peint)

; Peint : sous-rangées [A, B) de Col54 = PCoul ; marque les cellules de
; A et de B : Mark de la cellule, bit 0 si la sous-rangée la coupe
; (cellule mêlée), bit 1 si c'est son bord du haut (une nouvelle plage
; commence) ; MarkT[j] = (cellule, bit). Détruit D, X, Y, U, W.
Peint:
    STA     PA
    CMPB    PA
    BLS     Pe_Fin
    STB     PB
    LDX     #MarkT                  ; les marques de A et de B
    LDU     #Mark
    ASLA
    LDD     A,X
    ORB     A,U
    STB     A,U
    LDA     PB
    ASLA
    LDD     A,X
    ORB     A,U
    STB     A,U
    LDB     PB
    SUBB    PA
    CLRA
    TFR     D,W
    LDB     PA
    LDY     #Col54
    LEAY    B,Y
    LDX     #PCoul
    TFM     X,Y+
Pe_Fin:
    RTS

; Bande : D = i_out (DIn = i_in, CurC = la dernière case sous le tablier)
; -> le parapet (Parapet), puis la pierre PONT_COUL sur le ciel jusqu'à
; HORIZON - PBot2[i_out / 2] (x Q_ARC / 256 si CurC est le pied de
; l'arche) ; BandeF, toutes les cellules mêlées (le mur, plus loin, ne
; peindra que le ciel : PeintC). Détruit D, X.
Bande:
    STD     Iout
    LDD     DIn
    BSR     Parapet
    LDD     Iout
    LSRA
    RORB
    LDX     #PBot2
    LDA     D,X
    LDB     CurC                    ; le pied de l'arche : plus bas
    BITB    #ARC_F
    BEQ     Bd_B
    LDB     #Q_ARC
    MUL
Bd_B:
    NEGA
    ADDA    #HORIZON
    TFR     A,B
    LDA     #PONT_COUL
    STA     PCoul
    LDA     Hp
    BSR     Ciel
    ; (continue dans Melees)

; Melees : BandeF, toutes les cellules de la colonne mêlées. Détruit A, B, X.
Melees:
    LDA     #1
    STA     BandeF
    LDX     #Mark
    LDB     #VUE_H
Bd_Mark:
    LDA     ,X
    ORA     #1
    STA     ,X+
    DECB
    BNE     Bd_Mark
    RTS

; Parapet : D = indice -> le parapet GARDE_COUL sur le ciel, [HORIZON - pg,
; HORIZON - pt) (pt = PTop2[i / 2], pg = pt + pt x Q_GARDE / 256, au plus
; HORIZON) ; Hp = HORIZON - pt (le dessus du tablier). Détruit D, X.
Parapet:
    LSRA
    RORB
    LDX     #PTop2
    LDA     D,X
    STA     Pt
    LDB     #HORIZON
    SUBB    Pt
    STB     Hp
    LDB     #Q_GARDE
    MUL
    ADDA    Pt
    CMPA    #HORIZON
    BLS     Pp_Ok
    LDA     #HORIZON
Pp_Ok:
    NEGA
    ADDA    #HORIZON
    LDB     #GARDE_COUL
    STB     PCoul
    LDB     Hp
    ; (continue dans Ciel)

; Ciel : les sous-rangées [A, B) (au-dessus de l'horizon) qui sont encore
; du ciel = PCoul. Détruit A, B, X.
Ciel:
    STB     PB
    CMPA    PB
    BHS     Ci_Fin
    LDX     #Col54
    LEAX    A,X
    NEGA
    ADDA    PB
    TFR     A,B
Ci_Rang:
    LDA     ,X
    CMPA    #CIEL
    BNE     Ci_Pas
    LDA     PCoul
    STA     ,X
Ci_Pas:
    LEAX    1,X
    DECB
    BNE     Ci_Rang
Ci_Fin:
    RTS

; Mur_Pont : une culée ou un remblai (au sol), à l'indice Idx : le
; parapet, puis la pierre de Hp jusqu'au pied (BasC), le ciel seul
; au-dessus de l'horizon ; BasC = Hp. Le rayon continue au-dessus.
Mur_Pont:
    LDD     Idx
    BSR     Parapet
    BSR     Melees
    LDA     Hp
    CMPA    BasC
    BHS     MP_Fin
    LDB     #PONT_COUL
    STB     PCoul
    LDB     BasC
    STA     BasC
    JMP     PeintC
MP_Fin:
    RTS

; Muret : un mur bas à l'indice Idx : la pierre depuis HORIZON + Bas[Idx] x
; Q_MUR / 256 jusqu'au pied (BasC) ; BasC = ce haut.
Muret:
    LDX     #Bas
    LDD     Idx
    LDA     D,X
    LDB     #Q_MUR
    MUL
    ADDA    #HORIZON
    CMPA    BasC
    BHS     MP_Fin
    LDB     BasC
    STA     BasC
    PSHS    A
    LDA     #PONT_COUL
    STA     PCoul
    PULS    A
    JMP     Peint

; Fenetres : le mur PCoul de A à B (BasC) avec une sous-rangée sur 3
; noire (k mod 3 = 2), sur le ciel seul au-dessus de l'horizon ; toutes
; les cellules mêlées. Fin du rayon.
Fenetres:
    STA     PA
    STB     PB
    JSR     Melees
    LDA     PA
    CMPA    PB
    BHS     Fe_Fin
    CLRB                            ; B = PA mod 3
    LDA     PA
Fe_Mod:
    CMPA    #3
    BLO     Fe_M
    SUBA    #3
    BRA     Fe_Mod
Fe_M:
    TFR     A,B
    LDX     #Col54
    LDA     PA
    LEAX    A,X
Fe_Rang:
    LDA     PA
    CMPA    #HORIZON
    BHS     Fe_Ecrit
    LDA     ,X
    CMPA    #CIEL
    BNE     Fe_Pas
Fe_Ecrit:
    LDA     PCoul
    CMPB    #2
    BNE     Fe_Pose
    CLRA
Fe_Pose:
    STA     ,X
Fe_Pas:
    LEAX    1,X
    INCB
    CMPB    #3
    BLO     Fe_B
    CLRB
Fe_B:
    INC     PA
    LDA     PA
    CMPA    PB
    BLO     Fe_Rang
Fe_Fin:
    RTS

; PeintC : comme Peint, mais au-dessus de l'horizon seulement le ciel
; (une bande de tablier est devant ; les marques sont déjà mêlées).
PeintC:
    STA     PA
    STB     PB
    CMPA    #HORIZON
    BHS     PC_Sol
    LDX     #Col54
    LEAX    A,X
    LDB     PB
    CMPB    #HORIZON
    BLS     PC_N
    LDB     #HORIZON
PC_N:
    SUBB    PA
    BLS     PC_Sol
PC_Rang:
    LDA     ,X
    CMPA    #CIEL
    BNE     PC_Pas
    LDA     PCoul
    STA     ,X
PC_Pas:
    LEAX    1,X
    DECB
    BNE     PC_Rang
PC_Sol:
    LDA     PA                      ; sous l'horizon : Peint
    CMPA    #HORIZON
    BHS     PC_P
    LDA     #HORIZON
PC_P:
    LDB     PB
    JMP     Peint

; Composer : Col54 -> 18 cellules de la colonne Col de Want (osm3d.py,
; cellule : fond = la première de v2, v1, v0 non atténuée ; premier plan
; = la première de v0, v1, v2 qui n'est pas le fond). Par plages : une
; cellule sans marque continue la plage d'avant (même couleur, UniCel) ;
; une cellule mêlée est calculée. Mark[18] = $FF : la fin.
Composer:
    LDX     PtrWant
    LDB     Col
    ABX
    ABX
    LDU     #Col54
    LDY     #Mark
Co_Cel:
    LDA     ,Y+                     ; (Y : la marque de la cellule suivante)
    BMI     Co_Fin
    BITA    #1
    BNE     Co_Mix
    LDA     ,U                      ; une plage d'une couleur
    ASLA
    PSHS    X
    LDX     #UniCel
    LDW     A,X
    PULS    X
Co_Plage:
    STW     ,X
    LEAX    RANG_O,X
    LEAU    3,U
    TST     ,Y+
    BEQ     Co_Plage
    LEAY    -1,Y
    BRA     Co_Cel
Co_Fin:
    RTS
Co_Mix:
    LDA     2,U                     ; le fond
    CMPA    #8
    BLO     Co_Fond
    LDA     1,U
    CMPA    #8
    BLO     Co_Fond
    LDA     ,U
    CMPA    #8
    BLO     Co_Fond
    CLRA
Co_Fond:
    STA     Fond
    LDB     ,U                      ; le premier plan
    CMPB    Fond
    BNE     Co_Avant
    LDB     1,U
    CMPB    Fond
    BNE     Co_Avant
    LDB     2,U
    CMPB    Fond
    BNE     Co_Avant
    LDA     TabMos                  ; une seule couleur
    STA     ,X
    LDB     Fond
    LDA     #$10
    MUL
    ORB     #$88
    STB     1,X
    BRA     Co_Suiv
Co_Avant:
    STB     Avant
    CLRA                            ; le masque
    CMPB    ,U
    BNE     Co_M1
    ORA     #3
Co_M1:
    CMPB    1,U
    BNE     Co_M2
    ORA     #12
Co_M2:
    CMPB    2,U
    BNE     Co_M3
    ORA     #48
Co_M3:
    PSHS    Y
    LDY     #TabMos
    LDA     A,Y
    PULS    Y
    STA     ,X
    LDB     Fond
    LDA     #$10
    MUL
    ORB     #$80
    LDA     Avant
    BNE     Co_Av
    LDA     #8
Co_Av:
    STA     Tmp4
    ORB     Tmp4
    STB     1,X
Co_Suiv:
    LEAX    RANG_O,X
    LEAU    3,U
    LBRA    Co_Cel

; -------------------------------------------------------------------
; Marquer : les rangées de Want qui diffèrent de Pret partent (file vide :
; l'IRQ ne lit pas Pret), puis Want et Pret s'échangent.
; -------------------------------------------------------------------
Marquer:
    CLR     Rang
Ma_Rangee:
    LDB     Rang
    LDA     #RANG_O
    MUL
    STD     Decal
    LDX     PtrWant
    LEAX    D,X
    LDY     PtrPret
    LEAY    D,Y
    LDA     #RANG_O/8
    STA     Compte
Ma_Comp:                            ; 4 mots par tour
    LDD     ,X++
    CMPD    ,Y++
    BNE     Ma_Change
    LDD     ,X++
    CMPD    ,Y++
    BNE     Ma_Change
    LDD     ,X++
    CMPD    ,Y++
    BNE     Ma_Change
    LDD     ,X++
    CMPD    ,Y++
    BNE     Ma_Change
    DEC     Compte
    BNE     Ma_Comp
    BRA     Ma_Suiv
Ma_Change:
    LDX     PtrWant                 ; source : Want (le futur Pret)
    LDD     Decal
    LEAX    D,X
    LDB     Rang                    ; destination : la rangée en VRAM
    LDA     #VRAM_LIGNE/2
    MUL
    ASLB
    ROLA
    ADDD    #VRAM_BASE
    TFR     D,Y
    LDD     #RANG_O
    JSR     Ajoute
Ma_Suiv:
    INC     Rang
    LDA     Rang
    CMPA    #VUE_H
    BLO     Ma_Rangee
    LDD     PtrWant
    LDX     PtrPret
    STD     PtrPret
    STX     PtrWant
    RTS

; -------------------------------------------------------------------
; Tampons : Want = A, Pret = B rempli de $FF (rien de tel à l'écran : la
; première image part en entier) ; le texte (rangées 18-21) ; le cadre de
; la mini-carte.
; -------------------------------------------------------------------
Init_Tampons:
    LDD     #BufA
    STD     PtrWant
    LDD     #BufB
    STD     PtrPret
    LDA     #$FF
    STA     Tmp4
    LDX     #Tmp4
    LDY     #BufB
    LDW     #$900
    TFM     X,Y+
    LDX     #TxtBuf                 ; 4 rangées vides
    LDY     #4*80
    JSR     Vide_Cel
    LDX     #TxtAide                ; l'aide, rangée 20
    LDY     #TxtBuf+(2*VRAM_LIGNE)
IT_Aide:
    LDA     ,X+
    BEQ     IT_Cadre
    STA     ,Y++
    LDA     #$07
    STA     -1,Y
    BRA     IT_Aide
IT_Cadre:
    LDX     #MiniBuf                ; le cadre : vide, puis ses traits
    LDY     #18*16
    JSR     Vide_Cel
    LDX     #MiniBuf
    LDA     #$DA
    LDB     #$BF
    BSR     IT_Bord
    LDX     #MiniBuf+(17*32)
    LDA     #$C0
    LDB     #$D9
    BSR     IT_Bord
    LDX     #MiniBuf+32             ; côtés
    LDB     #16
IT_Cote:
    LDA     #$B3
    STA     ,X
    STA     30,X
    LDA     #CADRE_ATTR
    STA     1,X
    STA     31,X
    LEAX    32,X
    DECB
    BNE     IT_Cote
    LDX     #TxtPlan                ; le titre
    LDY     #MiniBuf+(5*2)
IT_Plan:
    LDA     ,X+
    BEQ     IT_Fin
    STA     ,Y++
    BRA     IT_Plan
IT_Fin:
    RTS
; IT_Bord : X = la rangée du cadre, A = coin gauche, B = coin droit
IT_Bord:
    STA     ,X
    STB     30,X
    LDA     #CADRE_ATTR
    STA     1,X
    STA     31,X
    LEAY    2,X
    LDB     #14
IB_Trait:
    LDA     #$C4
    STA     ,Y+
    LDA     #CADRE_ATTR
    STA     ,Y+
    DECB
    BNE     IB_Trait
    RTS

; Vide_Cel : X = des cellules, Y = leur nombre -> ($20, VIDE_ATTR)
Vide_Cel:
    LDD     #($20*256)+VIDE_ATTR
VC_Cel:
    STD     ,X++
    LEAY    -1,Y
    BNE     VC_Cel
    RTS

; -------------------------------------------------------------------
; Mini-carte (osm3d.py, mini) : refaite quand la case ou le quart de tour
; changent (file vide : l'IRQ ne lit pas MiniBuf), rangées 1-16 en file.
; -------------------------------------------------------------------
Mini_Si:
    LDD     Ang
    ADDD    #128
    ANDA    #3
    STA     Quart
    LDD     PosX
    CMPD    MiniX
    BNE     MS_Faire
    LDD     PosY
    CMPD    MiniY
    BNE     MS_Faire
    LDA     Quart
    CMPA    MiniQ
    BNE     MS_Faire
    RTS
MS_Faire:
    LDD     PosX
    STD     MiniX
    LDD     PosY
    STD     MiniY
    LDA     Quart
    STA     MiniQ
    LDD     PosY                    ; première rangée de points : y - 24
    SUBD    #24
    STD     Ligne
    LDY     #MiniBuf+32+2           ; la cellule (rangée 1, colonne 65)
    STY     MiPtr
    CLR     Rang
MS_Rang:
    LDX     #Pts0                   ; 3 rangées de 28 points
    BSR     Lit_Mini
    LDX     #Pts1
    BSR     Lit_Mini
    LDX     #Pts2
    BSR     Lit_Mini
    LDY     MiPtr
    CLRB
MS_Cel:
    PSHS    B
    LDX     #Pts0                   ; p0..p5 -> Vals
    ABX
    ABX
    LDD     ,X
    STD     Vals
    LDD     28,X
    STD     Vals+2
    LDD     56,X
    STD     Vals+4
    JSR     Cel_Mini
    STD     ,Y++
    PULS    B
    INCB
    CMPB    #MINI_L
    BLO     MS_Cel
    LDY     MiPtr
    LEAY    32,Y
    STY     MiPtr
    INC     Rang
    LDA     Rang
    CMPA    #MINI_H
    BLO     MS_Rang
    LDX     #Fleches                ; la flèche au centre
    LDB     Quart
    LDA     B,X
    LDB     #FLECHE_ATTR
    STD     MiniBuf+((1+(MINI_H/2))*32)+((1+(MINI_L/2))*2)
    LDX     #MiniBuf+32             ; rangées 1-16 en file
    LDY     #VRAM_BASE+VRAM_LIGNE+(64*2)
    LDB     #MINI_H
MS_File:
    PSHS    B,X,Y
    LDD     #32
    JSR     Ajoute
    PULS    B,X,Y
    LEAX    32,X
    LEAY    VRAM_LIGNE,Y
    DECB
    BNE     MS_File
    RTS

; Lit_Mini : X = 28 points (couleurs Mini) de la rangée Ligne, colonnes
; PosX - 28 + 2i ; Ligne avance d'une rangée.
Lit_Mini:
    STX     PtsPtr
    LDA     #(S_BATI*16)+S_BATI     ; d'abord du bâti partout
    STA     Tmp4
    LDX     #Tmp4
    LDY     #RowBuf
    LDW     #28
    TFM     X,Y+
    LDD     Ligne                   ; hors de la carte : bâti
    CMPD    #CARTE_H
    LBHS    LM_Conv
    LDD     PosX                    ; premier octet : (x - 28) / 2 (signé)
    SUBD    #28
    ASRA
    RORB
    STD     Sb
    CLR     Off                     ; décalage dans RowBuf
    LDD     #28
    STD     Nb
    LDD     Sb                      ; avant le début de la rangée : on coupe
    BPL     LM_Fin
    COMA
    COMB
    ADDD    #1
    STB     Off
    LDD     Nb
    SUBB    Off
    SBCA    #0
    STD     Nb
    CLRA
    CLRB
    STD     Sb
LM_Fin:
    LDD     Sb                      ; après la fin : on coupe
    ADDD    Nb
    CMPD    #256
    BLS     LM_Lit
    SUBD    #256
    PSHS    D
    LDD     Nb
    SUBD    ,S++
    STD     Nb
LM_Lit:
    LDD     Nb
    BLE     LM_Conv
    LDD     Ligne                   ; source : page 2 + y / 128, 256 (y mod 128) + Sb
    TFR     B,A
    ANDA    #127
    CLRB
    ADDD    Sb
    TFR     D,X
    LDY     #RowBuf
    LDB     Off
    LEAY    B,Y
    LDU     Nb
    LDA     Ligne+1
    LSLA
    LDA     #2
    ADCA    #0
    LDB     #1
    JSR     [table_function_ram+sys_FarRead]
LM_Conv:
    LDX     #RowBuf                 ; 28 points : le quartet haut si x pair
    LDY     PtsPtr                  ; (MiniHi, MiniLo : rangées dans l'ordre
    LDU     #MiniHi+128             ;  signé, l'octet est l'indice B,U)
    LDA     PosX+1
    BITA    #1
    BEQ     LM_Pair
    LDU     #MiniLo+128
LM_Pair:
    LDA     #28
    STA     Compte
LM_Point:
    LDB     ,X+
    LDA     B,U
    STA     ,Y+
    DEC     Compte
    BNE     LM_Point
    LDD     Ligne
    ADDD    #1
    STD     Ligne
    RTS

; Cel_Mini : Vals (6 points) -> A = glyphe, B = attribut (fond = le dernier
; point non atténué en partant de p5, sinon 0 ; premier plan = le premier qui
; en diffère : osm3d.py, cellule). Préserve Y, U.
Cel_Mini:
    LDX     #Vals+6                 ; le fond : le dernier point non atténué
    LDB     #6                      ; (en partant de p5), sinon 0
CM_F:
    LDA     ,-X
    CMPA    #8
    BLO     CM_FOk
    DECB
    BNE     CM_F
    CLRA
CM_FOk:
    STA     Fond
    LDX     #Vals                   ; le premier plan : le premier qui en diffère
    LDB     #6
CM_Av1:
    LDA     ,X+
    CMPA    Fond
    BNE     CM_Avant
    DECB
    BNE     CM_Av1
    LDA     Fond                    ; une seule couleur
    LDX     #UniMini
    ASLA
    LDD     A,X
    RTS
CM_Avant:
    STA     Avant
    TFR     A,B
    CLRA                            ; le masque
    CMPB    Vals
    BNE     CM_1
    ORA     #1
CM_1:
    CMPB    Vals+1
    BNE     CM_2
    ORA     #2
CM_2:
    CMPB    Vals+2
    BNE     CM_3
    ORA     #4
CM_3:
    CMPB    Vals+3
    BNE     CM_4
    ORA     #8
CM_4:
    CMPB    Vals+4
    BNE     CM_4b
    ORA     #16
CM_4b:
    CMPB    Vals+5
    BNE     CM_5
    ORA     #32
CM_5:
    LDX     #TabMos
    LDA     A,X
    PSHS    A
    LDX     #Shl4                   ; $80 + fond x 16
    LDB     Fond
    LDB     B,X
    LDA     Avant
    BNE     CM_Av
    LDA     #8
CM_Av:
    PSHS    A
    ORB     ,S+
    PULS    A,PC

; -------------------------------------------------------------------
; Plaque (rangée 19) : le nom de la rue du pâté 4 x 4 (OSM3D.RUE : plages
; par rangée de pâtés) ; refaite quand le numéro change (file vide).
; -------------------------------------------------------------------
Plaque_Si:
    JSR     Num_Rue
    CMPB    PlqNum
    BNE     PS_Faire
    RTS
PS_Faire:
    STB     PlqNum
    LDX     #TxtBuf+VRAM_LIGNE      ; la rangée 19 : vide
    LDY     #80
    JSR     Vide_Cel
    LDB     PlqNum
    BEQ     PS_File
    DECB                            ; X = le nom
    CLRA
    ASLB
    ROLA
    LDX     >RUES_ADR
    LDX     D,X
    STX     Tmp2
    CLRB                            ; sa longueur
PS_Long:
    TST     ,X+
    BEQ     PS_LongFin
    INCB
    BRA     PS_Long
PS_LongFin:
    ADDB    #2                      ; avec les deux espaces
    LSRB
    NEGB
    ADDB    #VUE_L/2                ; colonne de départ : 32 - L / 2
    LDX     #TxtBuf+VRAM_LIGNE
    ABX
    ABX
    LDB     #PLQ_ATTR
    LDA     #$20
    STD     ,X++
    LDY     Tmp2
PS_Nom:
    LDA     ,Y+
    BEQ     PS_Esp
    STD     ,X++
    BRA     PS_Nom
PS_Esp:
    LDA     #$20
    STD     ,X++
PS_File:
    LDX     #TxtBuf+VRAM_LIGNE
    LDY     #VRAM_BASE+(PLQ_RANG*VRAM_LIGNE)
    LDD     #VRAM_LIGNE
    JMP     Ajoute

; Num_Rue : PosX, PosY -> B = le numéro de la rue du pâté (0 : aucune)
Num_Rue:
    LDD     PosY                    ; rangée de pâtés : y / 4
    LSRA
    RORB
    LSRA
    RORB
    ASLB
    LDX     #RUES_ADR+2
    ABX
    LDX     ,X                      ; ses plages
    LDD     PosX                    ; colonne de pâtés : x / 4
    LSRA
    RORB
    LSRA
    RORB
    STB     Tmp4
    CLRB                            ; B = la colonne où finit la plage
NR_Plage:
    ADDB    ,X++
    BCS     NR_Trouve               ; (au-delà de 255 : c'est celle-ci)
    CMPB    Tmp4
    BLS     NR_Plage
NR_Trouve:
    LDB     -1,X
    RTS

; -------------------------------------------------------------------
; Données
; -------------------------------------------------------------------
    include "osm3d_data.inc"
Ry614:      fdb RY
C107:       fdb 107                 ; 1 / 2,4 rangée par unité (x 256)
NomCarte:   fcn "OSM3D.MAP"
NomRues:    fcn "OSM3D.RUE"
TxtPlan:    fcn " PLAN "
DepartX:    fdb DEPART_X            ; (le vérificateur peut les changer)
DepartY:    fdb DEPART_Y
DepartA:    fdb DEPART_A

; -------------------------------------------------------------------
; Variables
; -------------------------------------------------------------------
PosX        rmb 2                   ; la case (x) ...
FrX         rmb 1                   ; ... et sa fraction (24 bits en tout)
PosY        rmb 2
FrY         rmb 1
Ang         rmb 2
AncY        rmb 2
KeyHaut     rmb 1
KeyBas      rmb 1
KeyGauche   rmb 1
KeyDroite   rmb 1
Tourne      rmb 1               ; pas de rotation en attente (signé)
Niv         rmb 1               ; l'étage : 0 au sol, 1 sur un pont
MasqD       rmb 1               ; DESSOUS si au sol (les tabliers en bande), sinon 0
MasqM       rmb 1               ; MUR_P si au sol (culées et remblais en murs), sinon 0
Hp          rmb 1               ; Parapet : HORIZON - PTop2 (le dessus du tablier)
Pt          rmb 1
Iout        rmb 2
BandeF      rmb 1               ; une bande de tablier dans la colonne
DIn         rmb 2               ; l'indice où le rayon est passé sous le tablier
PBas        rmb 1
KbE0        rmb 1
KbRel       rmb 1
QuitReq     rmb 1
EscUp       rmb 1
Trames      rmb 1
TickImage   rmb 2
TickVu      rmb 2
AncienIRQ   rmb 2
JqT         rmb 1
JqQ         rmb 1
Reste       rmb 2
Jobs        rmb 6*JOBS_N
PtrWant     rmb 2
PtrPret     rmb 2
Pas         rmb 2
DepX        rmb 2
DepY        rmb 2
Dep         rmb 2
Marge       rmb 2
Signe       rmb 1
NouvP       rmb 3
NouvC       rmb 2
SinK        rmb 1
Tmp4        rmb 4
Tmp2        rmb 2
CrY         rmb 2
Ligne       rmb 2
Compte      rmb 1
Col         rmb 1
RayA        rmb 2
DltX        rmb 2
DltY        rmb 2
PasX        rmb 2
PasY        rmb 2
SideX       rmb 2
SideY       rmb 2
RayD        rmb 2
RX          rmb 2
NYr         rmb 1
Cote        rmb 1
Sorte       rmb 1
Idx         rmb 2
CosR        rmb 2
CellP       rmb 2
CurC        rmb 1
NewC        rmb 1
BasC        rmb 1
PCoul       rmb 1
PA          rmb 1
PB          rmb 1
Mark        rmb VUE_H+1
Col54       rmb SOUS
Fond        rmb 1
Avant       rmb 1
Masque      rmb 1
Rang        rmb 1
Decal       rmb 2
MiniX       rmb 2
MiniY       rmb 2
MiniQ       rmb 1
Quart       rmb 1
MiPtr       rmb 2
PtsPtr      rmb 2
Pts0        rmb 28
Pts1        rmb 28
Pts2        rmb 28
Vals        rmb 6
RowBuf      rmb 28
Sb          rmb 2
Off         rmb 1
Nb          rmb 2
PlqNum      rmb 1
NomFmt      rmb 16
Fin_Code:
