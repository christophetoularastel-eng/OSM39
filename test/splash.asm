; ===================================================================
; test/splash.asm - LE RENDU DU SPLASH, source unique du banc
; -------------------------------------------------------------------
; Ce fichier est un INCLUDE, pas un module autonome : il ne declare ni
; `section`, ni `export`, ni `end`. Il est insere par les etapes apres
; leur `start:` (voir test/stage3_splash.asm pour pourquoi l'ordre
; compte : le moniteur fait `JSR $0000`).
;
; Il remplace la copie de splash_draw qui etait dans common.inc. Il y
; avait trois copies du rendu dans le depot -- celle-ci,
; common.inc et bios/splash.asm -- et elles divergeaient deja. Une
; seule source, c'est la seule facon que le banc teste ce qui est
; livre.
;
; -------------------------------------------------------------------
; AUCUN APPEL AU BIOS
; -------------------------------------------------------------------
; Ni video_wait_vsync, ni PUTCHARV, ni aucune adresse de code : le
; banc doit tourner sur la carte telle qu'elle est flashee, et cette
; EPROM est un build anterieur a splash.asm, donc on ne connait pas
; son plan memoire. Un `jsr` code en dur appellerait n'importe quoi
; -- c'est ce qui est arrive au premier essai (ecran noir, CPU jamais
; entre dans le banc). Seules adresses utilisees : $A120 et
; $8000-$9FFF, qui sont materielles.
;
; CARTE V4 : caracteres en $8000-$8FFF, couleurs en $9000-$9FFF (meme
; cellule + VRAM_COL_OFS = $1000). VRAM_CTRL ne choisit plus que la
; page (D0-D2) : on y ecrit $00 une fois, et plus jamais $08 (RAM
; couleurs) ni $10 (mode affichage), que la carte ignore desormais.
;
; Consequence : contrairement a bios/splash.asm, ce rendu ne fait NI
; l'attente de trames de la fin, NI le `lda #$0C / jsr PUTCHARV`
; d'effacement. L'etape 4 traite l'effacement, et rien ici n'a besoin
; d'attendre.
;
; -------------------------------------------------------------------
; LE CALCUL D'ADRESSE, ET LE PIEGE DU `mul`
; -------------------------------------------------------------------
; Une position se calcule ligne x 80 + colonne, plus la base $8000.
; La version qui vit dans bios/splash.asm fait :
;         lda     ,x+                 ; A = ligne
;         ldb     #5
;         mul                         ; <-- FAUX
; `mul` calcule D x B, et D EST le couple A:B. Apres `ldb #5` on a
; donc D = (ligne << 8) | 5, et le resultat est
; ((ligne * 256) + 5) * 5 -- faux SUR UN 6809 DE BASE EGALEMENT, ce
; n'est donc pas une particularite 6309. Le premier ecran de la
; machine a ecrit ses caracteres dans la mauvaise fenetre.
;
; Deux raisons de ne pas repairer par unordonnancement : on ne peut
; pas tenir D = ligne dans l'octet bas de D ET B = 5 en meme temps
; (B EST l'octet bas de D), et `lwasm` ignore silencieusement
; l'operande registre de `mul x` / `mul y` / `mul u` pour toujours
; emettre le MUL simple, sans aucun diagnostic.
;
; On multiplie donc par une chaine de `addr`, qui sont des additions
; 16 bits sans ambiguite, et qui n'occupent jamais B :
;         addr    d,d                 ; ligne * 2
;         ...                        ; jusqu'a * 80
;
; ATTENTION : le bug est TOUJOURS present dans bios/splash.asm:169.
; On ne le corrige pas ici parce que ce banc doit d'abord le prouver
; sur la carte (etape 3). Le corriger et corriger la copie ensemble,
; dans le meme commit -- sinon le banc teste silencieusement une
; version que personne ne livre.
;
; -------------------------------------------------------------------
; FORMAT DE LA TABLE
; -------------------------------------------------------------------
; Ligne et colonne sont des MOTS de 16 bits, volontairement :
;         fdb  ligne,colonne
;         fcb  attribut
;         fcn  "texte"                <- FCN ajoute le NUL de fin
;         ...
;         fdb  $00FF,$0000 / fcb $00  fin de table
;
; Ce format differe de celui de bios/splash.asm, qui met ligne et
; colonne sur un seul octet. Il ne le peut pas faire : il n'existe
; AUCUN moyen non ambigu de faire passer un octet de table dans le
; registre ou l'on calcule l'adresse. B est le BAS de D (certain,
; Manuel 6309 §2), mais on ne sait pas si un acces a B atterrit
; aussi dans U -- la doc ne donne pas les positions de X/Y/U/S. Donc
; `ldu #0 / ldb ,x+` marche si B alias U et ne marche pas sinon, et
; `tfr b,u` vise une moitie dont personne n'a verifie quelle est.
; Stocker des mots et les charger par `ldu n,y` est correct dans les
; DEUX cas : aucune hypothese a faire.
; ===================================================================

; ===================================================================
; splash_clear - efface la page video 0 (espaces, noir sur noir)
; Entree : -            Sortie : -
; Detruit : A, B, D, X
; V4 : caracteres $8000-$8FFF puis couleurs $9000-$9FFF. Il n'y a plus
; de mode a rendre au 68B45 a la fin.
; ===================================================================
splash_clear:
        pshs    d,x,cc
        orcc    #%01010000          ; IRQ + FIRQ masques tant que le
                                    ; 68B45 lit la RAM
        lda     #$00                ; page 0
        sta     VRAM_CTRL
        ldx     #VRAM_BASE          ; RAM caracteres
        ldd     #$2020              ; deux espaces d'un coup
scl_char:
        std     ,x++
        cmpx    #VRAM_END
        bne     scl_char

        ldx     #VRAM_COL           ; RAM couleurs (V4 : a12 = 1)
        ldd     #SPL_BLACK          ; $0000 : noir sur noir
scl_attr:
        std     ,x++
        cmpx    #VRAM_COL_END
        bne     scl_attr
        puls    d,x,cc
        rts

; ===================================================================
; splash_draw - rend splash_data dans la fenetre video
; Entree : X = adresse de splash_data
; Sortie : page video 0 selectionnee (V4 : plus de mode affichage)
; Detruit : A, B, D, X, Y, U
;
; Y = pointeur de table. X sert de scratch pour le calcul d'adresse.
; -------------------------------------------------------------------
; TROIS PIEGES VERIFIES ICI
;
; 1. `mul x`, `mul y`, `mul u` : lwasm IGNORE l'operande registre et
;    emet `3D`, c'est-a-dire le MUL simple D x B. Aucun diagnostic.
;    Donc n'ecris jamais `mul R` ici. C'est aussi ce qui rend le `mul`
;    du debut de ce fichier irreparable par un reordonnancement.
; 2. `addd #<sym>` a 16 bits EST legal et correct ($C3 = ADDD
;    immediat 16 bits, l'assembleur a raison, l'emulateur aussi) : le
;    Manuel de reference donne 4 colonnes et non 3, et `C3` occupe la
;    colonne "immediat" avec 3 octets. Ne pas "corriger" ca.
; 3. `LEAU` NE MODIFIE PAS Z, et le post-incrementation d'un indexe
;    vaut TOUJOURS UN REGISTRE (2 octets), jamais 1. Deux details
;    distincts, tous deux absents de la doc 6809 de ce depot :
;      - `stb ,x++` ecrit UN octet et avance X de DEUX. lwasm emet
;        $81 pour `,x++` et $80 pour `,x+` : ce n'est pas une echelle
;        1 contre 2, c'est le bit 0 du postbyte. Deux `stb ,x++` a la
;        suite ecrivent donc les octets 0, 2, 4... et laissent les
;        impairs intacts. C'est ce qui a revele que splash_bandes
;        (dans common.inc) remplissait l'ecran un octet sur deux.
;      - `attente` (dans common.inc) fermait sa boucle sur un `bne`
;        qui testait un Z que rien ne venait de poser. Constate sur la
;        carte le 28 septembre 2026 : ecran fige ET BREAK muet.
;    Regle : comparer X explicitement (`cmpx #VRAM_END / bne`), et ne
;    JAMAIS prendre U pour compteur avec un `bne` -- un test
;    d'egalite sur U 16 bits se fait avec `cmpu`.
;
; ADDRESSAGE : on n'utilise que la forme a offset 5 bits
; (`n,y` -> postbyte $20+n, registre dans les bits 2-0), qui est la
; plus standard, et `,y+` / `,u` pour l'incrementation. Aucune
; convention d'auto-incrementation 16 bits n'est donc supposee.
; Seule exception, imposee par la V4 : `stb VRAM_COL_OFS,u`, offset
; 16 bits ($1000), qui vise la RAM couleurs a la meme cellule.
; ===================================================================
splash_draw:
        pshs    d,x,y,u,cc
        orcc    #%01010000
        tfr     x,y                 ; Y = pointeur de table
        lda     #$00                ; page 0 (V4 : D0-D2 seuls comptent)
        sta     VRAM_CTRL
sd_next:
        ldu     0,y                 ; U = numero de ligne (2 octets)
        cmpu    #$00FF              ; $00FF = fin de table
        beq     sd_end

        tfr     u,d                 ; D = ligne
        tfr     d,x                 ; X = ligne (scratch du x5)
        addr    d,d                 ; D = ligne * 2
        addr    d,d                 ; ligne * 4
        addr    x,d                 ; ligne * 5
        addr    d,d                 ; ligne * 10
        addr    d,d                 ; ligne * 20
        addr    d,d                 ; ligne * 40
        addr    d,d                 ; ligne * 80

        ldu     2,y                 ; U = colonne
        addr    u,d                 ; D = ligne * 80 + colonne
        ldx     #VRAM_BASE
        addr    x,d                 ; + base de la fenetre video
        tfr     d,u                 ; U = adresse du 1er caractere

        ldb     4,y                 ; attribut, valable pour le segment
        leay    5,y                 ; Y = premier caractere
sd_chars:
        lda     ,y+
        beq     sd_seg_done         ; NUL = fin de segment

        ; V4 : plus de bascule $00/$08 de VRAM_CTRL entre les deux
        ; ecritures. Le plan est choisi par l'ADRESSE (a12).
        sta     ,u                  ; RAM caracteres, $8000-$8FFF
        stb     VRAM_COL_OFS,u      ; RAM couleurs, meme cellule + $1000

        leau    1,u
        bra     sd_chars
sd_seg_done:
        bra     sd_next             ; Y pointe deja le segment suivant
sd_end:
        ; V4 : plus de `lda #$10 / sta VRAM_CTRL`. La VRAM revient au
        ; 68B45 des que le CPU cesse d'y ecrire ; l'image s'affiche.
        puls    d,x,y,u,cc
        rts
