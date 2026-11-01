; ===================================================================
; splash.asm - Ecran de demarrage colore
; -------------------------------------------------------------------
; Appele depuis `main` (main.asm:56, appel en main.asm:143) entre le
; jingle sonore et le moniteur. Affiche le nom de la machine, son
; createur, la mention FOSS, et un petit logo ASCII colore.
;
; -------------------------------------------------------------------
; POURQUOI ECRIRE LA VRAM DIRECTEMENT, ET NON PASSER PAR PUTCHARV
; -------------------------------------------------------------------
; PUTCHARV n'ecrit que dans le tampon circulaire ASCII_BUF/COLOR_BUF
; (256 octets chacun, ram.asm:163-164), et handler_IRQ (IT.asm:68)
; ne vide que 8 caracteres par trame VSYNC (`LDX #8`, decremente a
; chaque caractere ecrit -- le commentaire de la meme ligne annonce
; 16, mais c'est le code qui fait foi : 8). Un ecran de 25 x 80 =
; 2000 caracteres demanderait donc 250 trames, soit plus de 4
; secondes -- et PUTCHARV se bloquerait en attendant que le tampon se
; vide (video.asm:198-203, boucle WAIT_LOOP). Le logo passe donc
; directement par la fenetre $8000-$8FFF, comme le fait deja
; sys_ClearScreen (video.asm:250-310).
;
; -------------------------------------------------------------------
; CONTRAINTE MATERIELLE (video/carto.txt:65-68)
; -------------------------------------------------------------------
; Le CPU ne doit toucher les RAM video que si D4 = D5 = 0 (mode
; "acces CPU") et seulement pendant VSYNC = 0 ; les autres
; combinaisons de D4/D5 laissent le 68B45 afficher. sys_ClearScreen
; n'attend pas VSYNC non plus : on procede de meme, l'ecran est de
; toute facon regenere a la trame suivante. Le retour en mode lecture
; CRTC (D4 = 1) se fait en fin de splash_screen, une fois l'ecran
; ecrit.
;
; -------------------------------------------------------------------
; CE N'EST PAS UN SERVICE DE LA TABLE DE DISPATCH
; -------------------------------------------------------------------
; C'est un appel direct depuis `main`, comme boot_jingle
; (audio.asm:72). Il n'y a donc aucun sys_* a ajouter, et ni
; ram.asm ni vectors.asm a toucher.
;
; -------------------------------------------------------------------
; PRESERVE : D, X, Y, U.  ENTREE : -.  SORTIE : ecran efface, etat
; de rendu remis a zero, pret pour le shell.
; ===================================================================
        include "hardware.inc"
        include "sysfunc.inc"

        export  splash_screen

        import  video_wait_vsync,PUTCHARV

; --- Attributs couleur (video/carto.txt:71-75) ---
; ⚠ LA CARTE A CHANGE LE 29 SEPTEMBRE 2026. Ce bloc decrivait
; l'ancienne carte et affirmait qu'il ne fallait pas clignoter par
; prudence (« D4 NC » puis reutilise). C'est faux sur la carte
; actuelle : D4 n'est plus un clignotement, c'est le FOND.
;
; Octet d'attribut, carte actuelle :
;     D0-D2  couleur du PREMIER PLAN   (0..7)
;     D3      luminosite du premier plan
;     D4-D6  couleur de FOND           (0..7)
;     D7      page du generateur
; Le clignotement et l'inversion par VSYNC ont DISPARU de cet octet.
; Un attribut est donc premier plan + fond PAR ADDITION.
;
; Correspondance numero -> teinte : MESUREE SUR LA CARTE le
; 30 septembre 2026, via le banc (etapes 1, 3 et 5). Ce n'est plus une
; hypothese, elle est donc ecrite ici comme un fait, avec sa source.
; L'ordre est celui du MC6847 classique. Point important observe :
; la teinte 7 est du BLANC, pas du gris, et +D3 ne lave pas
; uniformement vers le blanc -- $0E (jaune + brisant) reste jaune
; alors que $0F sort blanc. C'est une propriete de la palette, pas du
; code ; si la carte，表明 un jour autre chose, il n'y a QUE ce
; tableau a retoucher.
SPL_BLACK   equ $00          ; 0 noir
SPL_BLUE    equ $01          ; 1 bleu
SPL_GREEN   equ $02          ; 2 vert
SPL_CYAN    equ $03          ; 3 cyan
SPL_RED     equ $04          ; 4 rouge
SPL_MAGENTA equ $05          ; 5 magenta
SPL_YELLOW  equ $06          ; 6 jaune
SPL_WHITE   equ $07          ; 7 BLANC (et NON gris : observe le 30/09)
SPL_BRIGHT  equ $08          ; + D3 = luminosite du premier plan

SPL_CASE    equ SPL_CYAN                ; $03  cadre du logo
SPL_FACE    equ SPL_YELLOW+SPL_BRIGHT   ; $0E  traits du visage
SPL_PUPIL   equ SPL_RED+SPL_BRIGHT      ; $0C  pupilles
SPL_TITLE   equ SPL_YELLOW+SPL_BRIGHT   ; $0E  "OSM39 V2"
SPL_SUB     equ SPL_CYAN                ; $03  mention
SPL_NAME    equ SPL_WHITE+SPL_BRIGHT    ; $0F  createur

SPL_FRAMES  equ 120          ; 120 trames VSYNC ~ 2 s a 60 Hz

        section .code

; ===================================================================
; splash_screen - Ecran de demarrage
; Entree : -
; Sortie : ecran efface apres l'affichage, etat de rendu remis a zero
; ===================================================================
splash_screen:
        pshs    d,x,y,u,cc
        orcc    #%01010000          ; IRQ + FIRQ masques : on ecrit la
                                    ; VRAM sans risque que handler_IRQ
                                    ; n'y touche en meme temps
                                    ; ( meme masque que video.asm:252 )

        jsr     splash_clear        ; page 0 : espaces + fond noir
        jsr     splash_draw         ; logo + textes

        ; (V4 : rien a rendre au 68B45, la VRAM est a lui hors des
        ; acces du CPU ; l'image s'affiche des que les ecritures cessent)

        ; video_wait_vsync compte sur vsync_tick, incremente par
        ; handler_IRQ : il FAUT donc reactiver l'IRQ avant d'appeler,
        ; sinon la boucle d'attente ne termine jamais.
        andcc   #%10101111          ; CLI + CLF
        lde     #SPL_FRAMES
        jsr     video_wait_vsync

        ; Remise de la main au moniteur. $0C fait tomber PUTCHARV dans
        ; do_cls/sys_ClearScreen (video.asm:246-310), qui remet VRAM_PTR,
        ; vram_line_ptr, SCREEN_START_OFFSET, CUR_PAGE, le tampon
        ; circulaire, et la fenetre avec char_attribut comme fond.
        ;
        ; ⚠ CE N'EST PAS LE SPLASH QUI S'EFFACE LUI-MEME, et cette ligne
        ; ne doit PAS etre retiree au nom d'un « il s'efface 2 s plus
        ; tard ». C'est la SEULE remise a zero entre le splash et
        ; l'invite du moniteur : `Monitor` (main.asm:209) commence par
        ; `sys_PrintString` de `hello` puis de `prompt` et ne touche a
        ; aucun etat d'ecran -- `video_clean` n'est appele qu'au
        ; demarrage (main.asm:112), avant le splash. Sans cette ligne,
        ; l'invite s'ecrirait a VRAM_PTR, c'est-a-dire au milieu du
        ; logo. Comportement voulu : splash 2 s, puis invite sur un
        ; ecran propre.
        lda     #$0C
        jsr     PUTCHARV

        puls    d,x,y,u,cc,pc

; ===================================================================
; splash_clear - Efface la page video 0
; Entree : -            Sortie : -
; Deteint : A, B, D, X
; V4 : caracteres en $8000-$8FFF, couleurs en $9000-$9FFF.
; ===================================================================
splash_clear:
        lda     #$00                ; page 0
        sta     VRAM_CTRL
        ldx     #VRAM_BASE
        ldd     #$2020              ; deux espaces d'un coup
scl_char:
        std     ,x++
        cmpx    #VRAM_END
        bne     scl_char

        ldx     #VRAM_COL           ; RAM couleurs
        ldd     #SPL_BLACK          ; $0000 : fond noir
scl_attr:
        std     ,x++
        cmpx    #VRAM_COL_END
        bne     scl_attr
        rts

; ===================================================================
; splash_draw - Rend la table splash_data dans la fenetre video
; Entree : -            Sortie : -
; Deteint : A, B, D, X, Y, U
;
; Format de la table, volontairement lisible et pas optimise :
;     fcb  ligne,colonne,attribut  <- AUCUNE espace apres la virgule
;     fcn  "texte"            <- FCN termine la chaine par un NUL
;     ...
;     fcb  $FF                <- fin de table
;
; X = curseur de donnees, U = adresse d'ecriture courante,
; B = attribut du segment en cours, A = caractere courant.
; ===================================================================
splash_draw:
        ldx     #splash_data
sd_next:
        ldb     ,x+                 ; numero de ligne -> B
        cmpb    #$FF                ; $FF = fin de table
        beq     sd_end

        ; --- ligne * 80, par chaine `addr` ---
        ;
        ; `mul` NE PEUT PAS servir ici, et aucune permutation n'y
        ; remediait. `mul` calcule D x B, or B EST l'octet bas de D :
        ; on ne peut donc pas avoir D = ligne ET B = 5 au meme instant.
        ; L'ancien code faisait exactement ce qu'il ne fallait pas --
        ;
        ;     lda ,x+ / ldb #5 / mul
        ;
        ; ce qui calcule ((ligne * 256) + 5) * 5. Pour ligne = 4 :
        ; (1024 + 5) * 5 = 5145, puis les quatre `lsld` x16 donnent
        ; 82320, tronque a 16 bits. Et c'est FAUX SUR UN 6809 SIMPLE
        ; AUSSI : ce n'est donc pas un piege du mode natif, c'est
        ; simplement un produit D x B applique comme si D et B etaient
        ; independants. La premiere ecriture atterrissait n'importe ou
        ; en RAM basse, par-dessus le code en cours d'execution.
        ;
        ; `addr` n'a pas ce conflit : il ajoute deux REGISTRES, donc
        ; ligne * 5 = ligne * 4 + ligne se fait en deux doublings puis
        ; une addition avec une copie de `ligne`, puis quatre doublings
        ; pour passer de x5 a x80.
        ;
        ; Cette copie va dans U, qui est LIBRE a cet instant (l'adresse
        ; du segment precedent n'est plus vivante) et que le code
        ; ci-dessous reutilise apres. X, lui, reste le curseur de table
        ; et n'a aucune place de stockage de repli.
        clra                          ; D = $00_ligne. `clra` ne touche que
                                    ; E/F/H/N/Z/V, PAS le C, et rien ici
                                    ; ne lit C : le `beq` ci-dessus est
                                    ; deja passe et le prochain test de
                                    ; drapeau est le `beq` du NUL de fin
                                    ; de segment.
        tfr     d,u                  ; U = ligne
        addr    d,d                   ; D = ligne * 2
        addr    d,d                   ; D = ligne * 4
        addr    u,d                   ; D = ligne * 5   (le 4 + le 1)
        addr    d,d                   ; * 10
        addr    d,d                   ; * 20
        addr    d,d                   ; * 40
        addr    d,d                   ; * 80

        pshs    d                   ; D = ligne * 80
        lda     ,x+                 ; colonne
        ldb     #0                  ; D = colonne
        addd    1,s                 ; D = ligne * 80 + colonne
        leas    2,s
        addd    #VRAM_BASE
        tfr     d,u                 ; U = adresse du 1er caractere

        ldb     ,x+                 ; B = attribut, conserve sur tout
                                    ; le segment
sd_chars:
        lda     ,x+                 ; caractere suivant
        beq     sd_seg_done         ; NUL = fin de segment

        sta     ,u                  ; RAM caracteres
        stb     VRAM_COL_OFS,u      ; RAM couleurs, 4 Ko plus haut

        leau    1,u                 ; offset suivant
        bra     sd_chars

sd_seg_done:
        bra     sd_next
sd_end:
        rts

; ===================================================================
; splash_data - Contenu de l'ecran
; -------------------------------------------------------------------
; Fenetre 80 x 25. Le logo occupe les colonnes 48 a 71, lignes 4 a 16.
; Les textes sont a gauche, colonne 3.
; Le logo est dessine en entier dans SPL_CASE, puis le visage est
; REDESSINE par-dessus dans SPL_FACE / SPL_PUPIL : la RAM couleur et
; la RAM caracteres sont deux pages distinctes, donc reecrire le meme
; offset avec un autre attribut ne fissure pas l'image.
; ===================================================================
splash_data:
; --- Logo : le cadre, en une seule couleur ---
        fcb  4,48,SPL_CASE
        fcn  " .--------------------. "
        fcb  5,48,SPL_CASE
        fcn  " /   o           o    / "
        fcb  6,48,SPL_CASE
        fcn  " /                    / "
        fcb  7,48,SPL_CASE
        fcn  " |       .----.       | "
        fcb  8,48,SPL_CASE
        fcn  " |      (  ..  )      | "
        fcb  9,48,SPL_CASE
        fcn  " |       (____)       | "
        fcb  10,48,SPL_CASE
        fcn  " |        \  /        | "
        fcb  11,48,SPL_CASE
        fcn  " |         \/         | "
        fcb  12,48,SPL_CASE
        fcn  " |         /\         | "
        fcb  13,48,SPL_CASE
        fcn  " |        /  \        | "
        fcb  14,48,SPL_CASE
        fcn  " \____________________/ "
        fcb  15,48,SPL_CASE
        fcn  "        ________        "
        fcb  16,48,SPL_CASE
        fcn  "       |________|       "

; --- Le visage, redessine par-dessus ---
        fcb  5,53,SPL_FACE       ; oeil gauche
        fcn  "o"
        fcb  5,65,SPL_FACE       ; oeil droit
        fcn  "o"
        fcb  7,57,SPL_FACE       ; arc superieur du sourire
        fcn  ".----."
        fcb  8,56,SPL_FACE
        fcn  "(  ..  )"
        fcb  8,58,SPL_PUPIL      ; les deux pupilles
        fcn  ".."
        fcb  9,57,SPL_FACE
        fcn  "(____)"
        fcb  10,58,SPL_FACE
        fcn  "\  /"
        fcb  11,59,SPL_FACE
        fcn  "\/"
        fcb  12,59,SPL_FACE
        fcn  "/\"
        fcb  13,58,SPL_FACE
        fcn  "/  \"

; --- Textes, a gauche ---
        fcb  6,3,SPL_TITLE
        fcn  "OSM39 V2"
        fcb  9,3,SPL_NAME
        fcn  "Christophe"
        fcb  12,3,SPL_SUB
        fcn  "FOSS 6809-HD6309"

        fcb  $FF                  ; fin de la table

        end
