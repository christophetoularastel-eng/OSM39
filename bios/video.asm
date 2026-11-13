; ===================================================================
; video.asm - Carte vidéo OSM39 (MC68B45 CRTC)
; -------------------------------------------------------------------
; MC68B45 CRTC + 2 RAMs vidéo (caractères 32 Ko, couleurs 32 Ko).
;
; V4 (carte CRT2 modifiée : U126 broche 1 sur a12, broches 2-3 à GND) :
;   $8000-$8FFF  RAM caractères   (VRAM_BASE .. VRAM_END)
;   $9000-$9FFF  RAM couleurs     (VRAM_COL .. VRAM_COL_END,
;                                  = caractère + VRAM_COL_OFS)
; Les deux plans sont TOUJOURS visibles du CPU ; hors des accès du CPU,
; la VRAM appartient au 68B45. Un accès perturbe l'image un instant :
; écrire pendant le retour de trame (VSYNC, IRQ).
; $A100: sélection registre CRTC, $A101: données CRTC.
; $A120: page RAM 4 Ko (D0-D1-D2 = page 0-7) ; D3-D5 ne servent plus
;        (en V3 : choix du plan et « mode affichage » $10).
;
; Mode texte 80×30 (le logiciel utilise 80×25 : VIDEO_ROWS), caractères
; 8×16, 525 lignes (VGA 640×480), horloge caractère 3.146875 MHz
; (25,175 MHz / 8 par le 74F163, Q2 = CHARCLOCK).
;
; VSYNC → IRQ (60 Hz tick + VRAM accessible pendant blanking).
; Convention 68B45 : valeur écrite = compte réel - 1
; (ex: R0=99 → 100 caractères, R4=31 → 32 rangées, R9=15 → 16 lignes/char ;
; R1 et R6 sont des comptes directs : R1=80 colonnes, R6=30 rangées).
; ===================================================================
        include "hardware.inc"
        include "sysfunc.inc"

        export video_init,video_clean, video_set_cursor_pos
        export video_wait_vsync,PUTCHARV,Console_Zone
        export X_Console_Zone,X_Zone_Cls
        include "ext.inc"
        import  ExtV
        import cz_actif,cz_l,cz_h,cz_haut,cz_bas,cz_op,cz_n,cz_ptr

        import table_function_ram
        import vsync_tick,SCREEN_START_OFFSET,char_attribut

; --- Constantes ---
CRTC_REGS       equ 18              ; nombre de registres à programmer
VIDEO_COLS      equ 80
VIDEO_ROWS      equ 25
VIDEO_BYTES     equ VIDEO_COLS*VIDEO_ROWS   ; 2000 octets par écran
VIDEO_ATTRIB    equ $32            ; gris sur noir


        section .code

; --- Table registres MC68B45 pour 80x25, 8x16, char clk 3.146875 MHz ---
; 100 char/ligne, 33 lignes (32+1) → ~59.6 Hz refresh.
;
; ⚠ R10 : LE COMMENTAIRE D'AUTREFOIS ETAIT FAUX, ET LA VALEUR
; L'ETAIT PLUS ENCORE. Tout est corrige ici le 30 septembre 2026.
;
; L'ancien commentaire disait << curseur desactive, bit 6=1 >> avec
; `fcb $cd`. C'etait faux deux fois : le bit 6 SEUL ne desactive
; rien, et `$cd` n'etait meme pas le mode qu'on croyait.
;
; Source : `../docs/MC6845P datasheet.pdf`, section CURSOR CONTROL
; << R10 is a 7-bit write-only register to define the start scan line
; and the cursor blink RATE. Bits 5 and 6 ... control cursor
; operation ... Non-display, DISPLAY, and two blink modes (16 times or
; 32 times the field period) are available. >>. Le TABLE 4 qui donne
; l'encodage est une IMAGE de ce PDF : `pdftotext` n'en sort que du
; bruit OCR et il n'y a aucun tesseract ici. L'encodage ci-dessous
; vient donc de cette Table 4 relue ailleurs, concordante sur trois
; sources, dont une implementation VHDL qui montre la logique :
;
;   cursor0 <= cursor_i                        when mode = "00" else
;              '0'                             when mode = "01" else
;              (cursor_i and field_counter(3)) when mode = "10" else
;              (cursor_i and field_counter(4));              -- mode "11"
;
;   bit 6 = 0, bit 5 = 0  ->  AFFICHE, sans clignotement
;   bit 6 = 0, bit 5 = 1  ->  NON AFFICHE
;   bit 6 = 1, bit 5 = 0  ->  clignotement x 1/16 de trame
;   bit 6 = 1, bit 5 = 1  ->  clignotement x 1/32 de trame
;
; ⚠ UNE PREMIERE VERSION DE CE COMMENTAIRE INVERSAIT LES DEUX
; PREMIERES LIGNES. Les bits se lisent colonne en premier : bit 6 =
; MSB, bit 5 = le suivant. Ne pas les permuter.
;
; $cd = 1100_1101 : bits 0-4 = 13 (ligne de debut), bit 5 = 0,
; bit 6 = 1, donc mode "10" = clignotement x 1/16. Or
; `field_counter(3)` ne vaut 1 qu'une fois sur 16 : le curseur n'etait
; donc present qu'environ 6 % de la trame. Consequence observee le
; 30 septembre 2026 sur la carte, et c'est elle qui a tranche :
;   << le caractere que je tapes n'est pas incorporable, mais
;      celui-la uniquement ; celui d'avant et celui d'apres
;      s'ecrivent bien. >>
; La cellule du curseur est la seule masquee, parce que c'est la
; seule ou le curseur force l'affichage. Ce n'est donc pas une
; cellule morte, et le symptome ne prouve aucun defaut d'ecriture.
;
; $0d = 0000_1101 : bits 0-4 = 13, bits 5 et 6 a 0 -> mode "00",
; le curseur est affiche en permanence. Le caractere tapes dessous
; redevient lisible (13 lignes sur 16 ; les 3 lignes du bas sont
; remplacees par le soulignement du curseur, ce qui est l'effet
; classique attendu). C'est le comportement d'un moniteur.
;
; R12/R13 = $ffff est le demarrage de fenetre ; R14/R15 sont une
; adresse RELATIVE A LA PAGE (le datasheet : << programmed to
; position the cursor anywhere in the refresh RAM area >>), ce qui
; explique que l'artefact suivait le defilement et revenait aux
; memes coordonnees sur les 8 pages. R16/R17 sont bien Light Pen
; (14 bits, LECTURE SEULE, capture par LPSTB) : ces noms-la sont
; corrects.
crtc_table:
        fcb $63   ; R0  HTOTAL : 100 caractères par ligne de balayage
        fcb $50   ; R1  HDISPLAY : 80 colonnes
        fcb $53   ; R2  HSYNC_POS : synchro au caractère 83
        fcb $06   ; R3  HSYNC_W : 6 caractères (VSYNC : 16 lignes, fixe)
        fcb $1f   ; R4  VTOTAL : 32 rangées de caractères (0..31)
        fcb $0d   ; R5  VADJUST : +13 lignes -> 32 x 16 + 13 = 525 (VGA)
        fcb $1e   ; R6  VDISPLAY : 30 rangées = 480 lignes (80 x 30)
        fcb $1e   ; R7  VSYNC_POS : synchro juste après la rangée 29
        ; R6/R7 = $1E depuis le 10 oct. 2026 (MIRE, touche V) : l'image
        ; commence 45 lignes après la synchro et l'écran en montre les 30
        ; rangées. Avec R7 = $1D (et 29 rangées), la rangée 0 tombait hors
        ; de la fenêtre de l'écran : c'était « la ligne 0 noire ».
        fcb $00   ; R8  pas d'entrelacement
        fcb $0F   ; R9  MAX_SCAN=15 → 16 lignes/caractère
        fcb $cd   ; R10 CURSOR_START : ligne 13, clignotement x1/16 (bits 6-5 = 10)
        fcb $cF   ; R11 CURSOR_END
        fcb $ff   ; R12 START_ADDR_H
        fcb $ff   ; R13 START_ADDR_L
        fcb $ff   ; R14 CURSOR_ADDR_H
        fcb $ff   ; R15 CURSOR_ADDR_L
        fcb $00   ; R16 LIGHT_PEN_H
        fcb $00   ; R17 LIGHT_PEN_L

; ===================================================================
; video_init - Initialise le CRTC 68B45 pour mode texte 80x25
; Entrée : -
; Sortie : Carry=0 ; tous les registres CRTC programmés, écran effacé
; ===================================================================
video_init:

        ldx     #crtc_table
        clrb                         ; B = numéro de registre (0..17)
vid_init_loop:
        stb     CRTC_RS              ; sélectionner registre B
        lda     ,x+                  ; valeur suivante
        sta     CRTC_DATA            ; programmer
        incb
        cmpb    #CRTC_REGS
        blo     vid_init_loop
        andcc   #%11111110           ; Carry=0
        rts

; ===================================================================
; video_wait_vsync - Attend le prochain front VSYNC (tick IRQ 68B40)
; Entrée : -
; Sortie : Carry=0 ; le tick VSYNC a changé (VRAM accessible)
; Préserve : X, D
;
; Le compteur T1 du 68B40 time-out à CHAQUE front VSYNC (compte=0, mode
; continu) et génère une IRQ. handler_IRQ (IT.asm) acquitte le 68B40
; (lecture Status $A081 + compteur T1) et incrémente vsync_tick (RAM
; système). On attend ici qu'il change.
;
; ATTENTION : le nombre de frames à attendre est fourni PAR L'APPELANT dans E
; (audio.asm : `LDE #55` puis JMP dans boot_jingle). Ne pas
; remplacer le `dece` par un compteur fixe : le délai deviendrait faux et le
; jingle de boot sortirait de son tempo.
; ===================================================================
video_wait_vsync:
        pshs    x,d                  ; préserver X, D
        pshsw
        ldx     #vsync_tick
new_vsink:
        ldd     ,x                   ; D = tick de départ
vid_wait_loop:
        cmpd    ,x                   ; tick a changé ?
        beq     vid_wait_loop
        dece
        bne new_vsink
        pulsw
        puls    x,d                  ; restaurer X, D
        andcc   #%11111110
        rts


; ===================================================================
; video_clean - rempli la ram de 0
; Entrée : -
; Sortie : Carry=0

; ===================================================================
video_clean:

        clr CUR_PAGE
        ldd     #-1
        STD     SCREEN_START_OFFSET
video_clean_loop:
        lda     CUR_PAGE                ; les 8 pages, l'une après l'autre
        sta     VRAM_CTRL
        ifne    CARTE_MONO
        ; --- mono : chaque case = espace puis attribut ---
        ldx     #VRAM_BASE
        lda     #$20
        ldb     char_attribut
vid_0_case:
        std     ,x++
        cmpx    #VRAM_END
        bne     vid_0_case
        else
        ; --- RAM couleur ($9000) : remplir d'attribut ---
        ldx     #VRAM_COL
        lda     char_attribut
        ldb     char_attribut
vid_0_attr:
        std     ,x++
        cmpx    #VRAM_COL_END
        bne     vid_0_attr
        ; --- RAM caractères ($8000) : espaces ---
        ldx     #VRAM_BASE
        ldd     #$2020
vid_0_char:
        std     ,x++
        cmpx    #VRAM_END
        bne     vid_0_char
        endc

        inc     CUR_PAGE
        lda     CUR_PAGE
        cmpa    #8
        blo     video_clean_loop
        clr     CUR_PAGE                ; on affiche la page 0
        clra
        sta     VRAM_CTRL           ; (latch en écriture seule : pas de CLR)
        andcc   #%11111110
        rts
; ===================================================================
; video_set_cursor_pos - Positionne le curseur matériel (R14/R15)
; Entrée : D = position (row * 80 + col), D < 2000
; Sortie : Carry=0
; ===================================================================
video_set_cursor_pos:
        pshs    a,b
        ; --- R14 : CURSOR_ADDR_H ---
        lda     #$0E
        sta     CRTC_RS
        lda     2,s                 ; A = high byte (original)
        sta     CRTC_DATA
        ; --- R15 : CURSOR_ADDR_L ---
        lda     #$0F
        sta     CRTC_RS
        lda     1,s                 ; B = low byte (original)
        sta     CRTC_DATA
        leas    2,s
        andcc   #%11111110
        rts

 ; ---------------------------------------------------------
; Entrée : A = Code ASCII, B = Attribut Couleur
; ---------------------------------------------------------
PUTCHARV:
        cmpa    #09
        beq do_tab
        cmpa    #$0c
        beq do_cls
PUTCHAR_NORMAL:
; --- GESTION DU TAMPON PLEIN AVEC MISE EN VEILLE ---
WAIT_LOOP:
        ; 2. Test du tampon plein
        LDE     BUF_HEAD    ; B = Pointeur d'écriture actuel
        INCE                ; B = Ce que sera le pointeur APRES écriture
        CMPE    BUF_TAIL    ; A-t-on rattrapé le pointeur de lecture ?
        BEQ     WAIT_LOOP   ; OUI : C'est plein ! On boucle à l'infini en attendant

        ; --- ÉCRITURE DANS LE TAMPON ---
        ; !!! NE PAS REECRIRE CE BLOC. A = caractère ASCII, B = couleur, et les
        ; deux doivent SURVIVRE jusqu'aux deux STA ; le `clra` servant au LEAX
        ; d'adressage est justement annulé par le `puls a` qui suit. Un
        ; `clra` + `STA ,X` naïf écrirait 0 dans ASCII_BUF et l'INDEX dans
        ; COLOR_BUF : écran détruit dès le premier caractère.
        ; PSHS X,d / pshs d ... puls a / PULS A ... PULS X,d,pc est un
        ; empilement volontaire, pas un déséquilibre de pile.
DO_WRITE:
        PSHS    X,d
        pshs d
        LDX     #ASCII_BUF
        LDB     BUF_HEAD    ; Index de destination (0-255)
        clra
        leax    d,x
        puls    a
        ; 2. Écrit l'ASCII et la Couleur
        STA     ,X         ; Écrit dans ASCII_BUF à l'offset B
        LDX     #COLOR_BUF
        clra
        leax    d,x
        PULS    A           ; A = Couleur
        STA     ,X         ; Écrit dans COLOR_BUF à l'offset B

        ; 3. Avance le pointeur (le passage de 255 à 0 est automatique !)
        INC    BUF_HEAD
        PULS    X,d,pc

do_tab:
        ; COMPTER DANS F. DO_WRITE fait `LDB BUF_HEAD`, donc B est déjà
        ; occupé par l'index d'écriture quand on revient ici : un `decb`
        ; compterait à partir de BUF_HEAD et non de 5. F n'est pas touché
        ; par DO_WRITE, le compteur est donc sur.
        ; (Faitceau de 8 colonnes = 8 "FDTAB".)
        ldf     #05
do_tab_loop:
        lda     #' '
        bsr PUTCHAR_NORMAL
        decf
        bne do_tab_loop
        rts
do_cls:
 ; ===================================================================
; sys_ClearScreen - Efface l'écran et réinitialise les pointeurs
; ===================================================================
sys_ClearScreen:
        TST     cz_actif
        LBNE    Zone_Cls
        PSHS    d,x,y,cc
        ORCC    #%01010000      ; Désactive les interruptions (FIRQ/IRQ) pendant la manip

        ; 1. Vider le tampon circulaire pour éviter d'afficher des "fantômes"
        CLR     BUF_HEAD
        CLR     BUF_TAIL

        ; 2. Réinitialiser les pointeurs virtuels de l'OS
        LDX     #VRAM_BASE      ; Normalement $8000
        STX     VRAM_PTR
        STX     vram_line_ptr

        ; 3. Réinitialiser le Scroll (Caméra du CRTC en haut de page)
        LDD     #-1
        STD     SCREEN_START_OFFSET

        ; 4. Effacer la VRAM Caractère (Espaces = $20), page CUR_PAGE
        LDA     CUR_PAGE
        STA     VRAM_CTRL

        LDX     #VRAM_BASE
        ifne    CARTE_MONO
        LDA     #$20            ; mono : espace et attribut, case par case
        LDB     char_attribut
Clear_Case_Loop:
        STD     ,X++
        CMPX    #VRAM_END
        BNE     Clear_Case_Loop
        else
        LDD     #$2020          ; D = Deux espaces d'un coup (plus rapide)
Clear_Char_Loop:
        STD     ,X++
        CMPX    #VRAM_END
        BNE     Clear_Char_Loop

        ; 5. Effacer la VRAM Couleur (Attribut par défaut), en $9000
        LDX     #VRAM_COL
        lda     char_attribut
        ldb     char_attribut

Clear_Color_Loop:
        STD     ,X++
        CMPX    #VRAM_COL_END
        BNE     Clear_Color_Loop
        endc

        ; 7. Mise à jour matérielle du 68B45 (Début d'écran R12/R13 à 0)
        LDA     #12
        STA     CRTC_RS
        lda     #-1
        sta     CRTC_DATA
        LDA     #13
        STA     CRTC_RS
        lda     #-1
        sta     CRTC_DATA

        PULS    d,x,y,cc,pc     ; Restaure tout et réactive les interruptions

    section .ext
; ===================================================================
; Console_Zone (service sys_Console_Zone) - la console dans un rectangle
; Entrée : A = colonne, B = rangée, E = largeur, F = hauteur (0..29),
;          Y = attribut du texte (octet bas), à l'ÉCRAN 80 x 30.
;          E = 0 : retour à la console plein écran (rien n'est effacé).
; La zone est effacée par l'IRQ (au fil des trames), le texte en attente
; est jeté, le curseur va en haut à gauche. Pas de défilement matériel :
; l'adresse de départ du 68B45 est remise à celle d'OSM-VISION ($FFFF).
; Préserve tout. C = 0.
; ===================================================================
X_Console_Zone:
        PSHS    d,x,y,u,cc
        PSHSW
        TSTE
        BNE     Cz_Pose
        CLR     cz_actif
        BRA     Cz_Fin
Cz_Pose:
        ORCC    #%01010000
        STE     cz_l
        STF     cz_h
        TFR     Y,X
        TFR     X,D                     ; (A, B relus plus bas depuis la pile)
        STB     char_attribut
        LDB     4,S                     ; rangée (pile : W 2, CC 1, A, B...)
        LDA     #80
        MUL
        ADDB    3,S                     ; + colonne
        ADCA    #0
        ifne    CARTE_MONO
        LSLB                            ; case -> octets
        ROLA
        endc
        ADDD    #VRAM_BASE
        STD     cz_haut
        STD     cz_ptr
        STD     VRAM_PTR
        STD     vram_line_ptr
        TFR     D,X
        LDB     cz_h
        DECB
        LDA     #VRAM_LIGNE
        MUL
        LEAX    D,X
        STX     cz_bas
        LDA     BUF_HEAD                ; le texte en attente est jeté
        STA     BUF_TAIL
        LDD     #-1                     ; affichage d'OSM-VISION : départ $FFFF, page 0
        STD     SCREEN_START_OFFSET
        LDA     #12
        STA     CRTC_RS
        LDA     #$FF
        STA     CRTC_DATA
        LDA     #13
        STA     CRTC_RS
        LDA     #$FF
        STA     CRTC_DATA
        CLR     CUR_PAGE
        LDA     cz_h                    ; la zone est effacée par l'IRQ
        STA     cz_n
        LDA     #2
        STA     cz_op
        STA     cz_actif
Cz_Fin:
        PULSW
        PULS    d,x,y,u,cc
        ANDCC   #$FE
        RTS

; $0C en zone : on efface la zone (par l'IRQ), le curseur en haut à gauche
X_Zone_Cls:
        PSHS    d,cc
        ORCC    #%01010000
        LDA     BUF_HEAD
        STA     BUF_TAIL
        LDD     cz_haut
        STD     VRAM_PTR
        STD     vram_line_ptr
        STD     cz_ptr
        LDA     cz_h
        STA     cz_n
        LDA     #2
        STA     cz_op
        PULS    d,cc,pc
    section .code
Console_Zone:
    jmp     [ExtV+EXTV_CZONE]
Zone_Cls:
    jmp     [ExtV+EXTV_ZONECLS]




        end
