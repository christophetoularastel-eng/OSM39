; ===================================================================
; video.asm - Carte vidéo OSM39 (MC68B45 CRTC)
; -------------------------------------------------------------------
; MC68B45 CRTC + 2 RAMs vidéo (caractères 32 Ko, couleurs 32 Ko)
; sélectionnées par le registre 74HC374 $A120.
;
; Fenêtre CPU: $8000-$9FFF (8 Ko), accès pendant VSYNC=0 (IRQ).
; $A100: sélection registre CRTC, $A101: données CRTC.
; Carte V4 : caractères en $8000-$8FFF, couleurs en $9000-$9FFF (a12
; sur U126). $A120 ne porte plus que la page (D0-D2) ; plus de bit
; char/couleur ni de mode d'affichage : hors des accès CPU, la VRAM
; est au CRTC.
;
; ⚠ COPIE FOSSILE de bios/video.asm (etat initial), incluse par AUCUNE
; etape et qui n'assemble pas seule (vsync_tick defini deux fois).
; Migree en V4 pour ne pas garder le schema $08/$10 dans le depot ;
; la reference est bios/video.asm.
;
; Mode texte 80×25, caractères 8×16, horloge caractère 3.146875 MHz
; (25,175 MHz / 8 par le 74F163, Q2 = CHARCLOCK).
;
; VSYNC → IRQ (60 Hz tick + VRAM accessible pendant blanking).
; Convention 68B45 : valeur écrite = compte réel - 1
; (ex: R1=79 → 80 colonnes, R6=24 → 25 lignes, R9=15 → 16 lignes/char).
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"
; --- Constantes ---
CRTC_REGS       equ 18              ; nombre de registres à programmer
VIDEO_COLS      equ 80
VIDEO_ROWS      equ 25
VIDEO_BYTES     equ VIDEO_COLS*VIDEO_ROWS   ; 2000 octets par écran
VIDEO_ATTRIB    equ $32            ; gris sur noir

; --- Bits $A120 (74HC374) ---
; V4 : le plan se choisit par l'adresse ; ces deux valeurs ne
; selectionnent plus que la page 0. ($04 aurait choisi la page 4.)
VID_CPU_CHAR    equ $00            ; page 0
VID_CPU_COLOR   equ $00            ; page 0 (couleurs a VRAM_COL)
vsync_tick      equ $C46B

        section .code

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
; ===================================================================
video_wait_vsync:
        pshs    x,d                  ; préserver X, D

        ldx     #vsync_tick
        ldd     ,x                   ; D = tick de départ
vid_wait_loop:
        cmpd    ,x                   ; tick a changé ?
        beq     vid_wait_loop
        lda     0,s
        sta     VRAM_CTRL
        puls    x,d                  ; restaurer X, D
        andcc   #%11111110
        rts

; ===================================================================
; video_clear - Efface l'écran caractère + attribut
; Entrée : -
; Sortie : Carry=0
;
; Remplit la RAM caractère de ' ' (0x20) et la RAM couleur de l'attribut
; vidéo par défaut. L'accès VRAM n'est sûr qu'en blanking VSYNC : 256
; octets par tick (~16 ms), donc ~8 frames pour 2000 octets.
; ===================================================================
video_clear:

        ; --- RAM couleur : remplir d'attribut (V4 : $9000-$9FFF) ---
        ldx     #VRAM_COL+1
        ldy     #38
vid_clear_attr:
        lda     #VID_CPU_COLOR
        jsr     video_wait_vsync
        lda     #VIDEO_ATTRIB
        ldb     #$3f
vid_fill_attr:
        sta     ,x+
        decb
        bne     vid_fill_attr
        ; (V4 : plus de `lda #8 / sta VRAM_CTRL` pour rendre la VRAM au 6845)
        leay    -1,y
        bne     vid_clear_attr

        ; --- RAM caractère : remplir de ' ' ---

        ldx     #VRAM_BASE+1
        ldy     #38                  ; 128 × 64 = 8192 octets (> 2000)
vid_clear_char:
        lda     #VID_CPU_CHAR
        jsr     video_wait_vsync
        lda     #$20
        ldb     #$3F                 ; 64 itérations (FF+1 = 0)
vid_fill_char:
        sta     ,x+
        inca
vid_fill_cont:
        decb
        bne     vid_fill_char
        ; (V4 : plus de `lda #8 / sta VRAM_CTRL` pour rendre la VRAM au 6845)
        leay    -1,y
        bne     vid_clear_char

        andcc   #%11111110
        rts
; ===================================================================
; video_clean - rempli la ram de 0
; Entrée : -
; Sortie : Carry=0

; ===================================================================
video_clean:
        lda #$08
        sta CUR_PAGE
        ; --- RAM couleur : remplir d'attribut (V4 : $9000-$9FFF) ---
        ldx     #VRAM_COL
        ldy     #38
vid_clean_attr:
        lda     #VID_CPU_COLOR
        jsr     video_wait_vsync
        lda     #$20
        ldb     #$3f
vid_0_attr:
        sta     ,x+
        decb
        bne     vid_0_attr
        ; (V4 : plus de `lda #8 / sta VRAM_CTRL` pour rendre la VRAM au 6845)
        leay    -1,y
        bne     vid_clean_attr

        ; --- RAM caractère : remplir de ' ' ---

        ldx     #VRAM_BASE
        ldy     #38                  ; 128 × 64 = 8192 octets (> 2000)
vid_clean_char:
        lda     #VID_CPU_CHAR
        jsr     video_wait_vsync
        lda     #' '
        ldb     #$3F                 ; 64 itérations (FF+1 = 0)
vid_0_char:
        sta     ,x+
        decb
        bne     vid_0_char
        ; (V4 : plus de `lda #8 / sta VRAM_CTRL` pour rendre la VRAM au 6845)
        leay    -1,y
        bne     vid_clean_char
        ldx     #VRAM_BASE
        stx     VRAM_PTR
        stx     vram_line_ptr
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
        PSHS    X,d
        LDX     #ASCII_BUF

        ; 1. Récupère le pointeur d'écriture
        PSHS    d           ; Sauvegarde B (Couleur)
        LDB     BUF_HEAD    ; Index de destination (0-255)
        clra
        leax    d,x
        puls    a
        cmpa    #09
        bne not_tab
        lda     #' '
        Sta     0,x
        Sta     1,x
        sta     2,x
        sta     3,x
        Sta     4,x
        sta     5,x
        sta     6,x
        sta     7,x
        LDX     #COLOR_BUF
        clra
        leax    d,x
        PULS    A           ; A = Couleur
        sta     0,x
        Sta     1,x
        Sta     2,x
        sta     3,x
        sta     4,x
        Sta     5,x
        sta     6,x
        sta     7,x

        lda    BUF_HEAD
        adda    #8
        Sta     BUF_HEAD
        puls x,d,pc

not_tab:
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

test:
        ldq     #$54321089
        divq	#$1234
        muld    #$25
        rts


        end
