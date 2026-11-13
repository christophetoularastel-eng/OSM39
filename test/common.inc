; ===================================================================
; test/common.inc - parties communes du banc d'essai du splash
; -------------------------------------------------------------------
; CE FICHIER NE CONTIENT AUCUN APPEL AU BIOS. C'est deliberé.
;
; Le banc doit tourner sur la carte telle qu'elle est flashée en ce
; moment, et cette EPROM est un build antérieur à splash.asm : on ne
; connaît pas son plan mémoire, donc `jsr video_wait_vsync` codé en
; dur appellerait n'importe quoi. Le premier essai l'a bien montré :
; le test s'est terminé sur un écran noir, et le CPU n'est
; jamais entré dans le banc.
;
; REGLE : le banc n'utilise QUE les adresses MATERIELLES, qui n'ont
; pas pu changer :
;     $A120       latch de selection de page video (VRAM_CTRL)
;     $8000-$8FFF RAM caracteres (4 Ko)
;     $9000-$9FFF RAM couleurs   (4 Ko)
;
; CARTE V4 (10 oct. 2026). L'entree A0 de U126 (74HC138) est cablee
; sur la ligne d'adresse a12 du CPU : les caracteres sont TOUJOURS en
; $8000-$8FFF et les couleurs TOUJOURS en $9000-$9FFF, a la meme
; cellule + $1000. VRAM_CTRL ne porte plus que la page (D0-D2) ; D3
; (caracteres/couleurs) et D4-D5 (« mode affichage », l'ancien $10)
; sont ignores par la carte. Il n'y a plus de mode a rendre au 68B45 :
; hors des acces du CPU, la VRAM est a lui. Ecrire $00 (page 0) reste
; correct et sans effet de bord. Avant la V4, on ecrivait $00 pour les
; caracteres, $08 pour les couleurs, toutes deux dans $8000-$8FFF, et
; $10 pour rendre l'image : ces trois ecritures n'existent plus ici.
;
; Aucune adresse RAM du BIOS (BSS), aucune adresse de code, aucun
; .inc genere dependent d'un build. Le banc est donc valable sur
; n'importe quelle version du BIOS.
;
; Seule exception : hardware.inc, dont on ne prend que VRAM_CTRL,
; VRAM_BASE, VRAM_END, VRAM_COL, VRAM_COL_END et VRAM_COL_OFS - des
; adresses materielles.
; Le portage du splash dans l'EPROM, phase suivante, pourra de
; nouveau appeler video_wait_vsync.
; ===================================================================

        include "../bios/hardware.inc"
        ; Les etapes 1 a 8 sont ecrites pour la V4 (deux plans de 4 Ko) :
        ; sur la mono, leurs boucles « plan couleurs » iraient jusqu'en
        ; $A000 (l'ACIA). La mono a son etape : stage9_mono.
        ifne    CARTE_MONO
        error   "etapes 1-8 : banc V4 seulement (CARTE = mono) ; voir stage9_mono"
        endc

; --- Attributs couleur (video/carto.txt:71-75) ------------------------
; MODIFICATION MATERIELLE du 29 septembre 2026. La carte a ete
; amelioree : l'octet d'attribut porte maintenant DEUX couleurs.
; Avant : D0-D2 couleur, D3 luminosite, D4 clignotement, D5
; complement a chaque VSYNC, D6 inversion, D7 page de police.
; Apres :
;     D0-D2  couleur du CARACTERE (premier plan)
;     D3     luminosite du caractere
;     D4-D6  couleur de FOND
;     D7     page 0 ou 1 du generateur de caracteres
; Le clignotement et l'inversion ont DISPARU de cet octet. Tout ce
; qui supposait les bits D4-D6 libres (l'ancien `SPL_BLACK` a zero
; signifiait « pas de clignotement ») doit etre relu.
;
; D7 reste a 0 : on n'utilise qu'une seule page de police.
;
; Ces constantes sont MESUREES, pas supposees : la correspondance a ete
; relevee a l'oeil sur la carte le 30 septembre 2026, via les etapes 1, 3
; et 5. L'ordre est celui du MC6847 classique, 0 noir ... 7 BLANC.
;
; Deux points qui ne se devinent pas et qui ont ete confirmes ici :
;   - la teinte 7 est du BLANC PUR, pas du gris. L'etape 5 le prouve :
;     sa bande 8 (fond 7) sort VIDE, parce que le premier plan y est
;     lui-meme du blanc.
;   - + D3 ne lave PAS uniformement vers le blanc. $0E (jaune + brisant)
;     reste jaune alors que $0F sort blanc : la teinte 6 reste saturee.
;     C'est une propriete de la palette, pas du code.
SPL_BLACK   equ $00
SPL_BLUE    equ $01
SPL_GREEN   equ $02
SPL_CYAN    equ $03
SPL_RED     equ $04
SPL_MAGENTA equ $05
SPL_YELLOW  equ $06
SPL_WHITE   equ $07          ; et NON gris : observe le 30 septembre 2026
SPL_BRIGHT  equ $08          ; + D3 = luminosite du caractere

; --- FOND : D4-D6, donc decale de 4 bits ---------------------------
; Le fond n'a PAS de bit de luminosite : D3 appartient au caractere.
; 8 fonds de 0 a 7, rien de plus. C'est ce que dit carto.txt:74
; ("D4,D5, et D6 couleur de fond"), et rien de plus.
;
; ⚠ L'ECRITURE SANS ESPACE CI-DESSOUS EST OBLIGATOIRE. DOUBLE PIEGE
; lwasm 4.24, tous deux SILENCIEUX, mesures le 30 septembre 2026 en
; relisant les octets REELS du binaire de l'etape 5 :
;
;   1. `equ 1 << 16` avec des espaces autour de l'operateur donne 1.
;      lwasm tronque l'expression AU PREMIER MOT : il garde `1` et jette
;      le reste, SANS AUCUN DIAGNOSTIC. `equ 15 + 1` donne 15, pas 16.
;      Ce n'est donc pas une question de precedence, ni de
;      parentheses : `(15 + 1)` echoue aussi. C'est la presence
;      d'ESPACES autour de l'operateur qui casse tout.
;   2. `<<` N'EST PAS UN OPERATEUR ICI. Meme sans espaces,
;      `equ 1<<16` est refuse : `Bad operand`. Il faut multiplier.
;
; Concretement, la palette ci-dessous donnait des fonds 0, 1, 2, 3,
; 4, 5, 6, 7 AU LIEU DE 0, 16, 32, 48, 64, 80, 96, 112 -- donc huit
; bandes qui ne changeaient QUE LE PREMIER PLAN, et jamais le fond.
; Ni l'assemblage ni
; verifie_rendu.py ne le voyaient : la table est relue dans le
; binaire et confrontée a une formule, mais la formule relue, c'est
; cette table-la. C'est en relisant les octets un par un qu'on l'a
; vu. Ne reintroduire ni espaces ni `<<`.
SPL_FOND       equ 4         ; nombre de bits de DECALAGE du fond
SPL_FOND_UN    equ 16        ; 2 puissance SPL_FOND. Multiplier, pas
                             ; decaler : `<<` est refuse par lwasm.
SPL_FOND_NOIR  equ 0
SPL_FOND_BLEU  equ 1*SPL_FOND_UN
SPL_FOND_VERT  equ 2*SPL_FOND_UN
SPL_FOND_CYAN  equ 3*SPL_FOND_UN
SPL_FOND_ROUGE equ 4*SPL_FOND_UN
SPL_FOND_MAG   equ 5*SPL_FOND_UN
SPL_FOND_JAUNE equ 6*SPL_FOND_UN
SPL_FOND_GRIS  equ 7*SPL_FOND_UN

; Un attribut se compose donc en additionnant premier plan et fond,
; les deux etant deja a leur place dans l'octet :
;     fcb SPL_PLAN+SPL_FOND_BLEU
; C'est plus lisible qu'un decalage fait a chaque fois, et ca rend
; impossible d'oublier le fond (un attribut a zero aurait un fond
; noir ET aucun caractere).Ici encore, AUCUN ESPACE autour du `+` : dans
; les `fcb` comme dans les `equ`, l'espace casse l'evaluation.
SPL_CASE    equ SPL_CYAN
SPL_FACE    equ SPL_YELLOW+SPL_BRIGHT
SPL_PUPIL   equ SPL_RED+SPL_BRIGHT
SPL_TITLE   equ SPL_YELLOW+SPL_BRIGHT
SPL_SUB     equ SPL_CYAN
SPL_NAME    equ SPL_WHITE+SPL_BRIGHT

; Le premier plan que l'etape 5 garde CONSTANT pendant que le fond, lui,
; varie de 0 a 7. Il est nomme pour que la table dise ce qu'elle fait :
; `fcb SPL_PLAN+SPL_FOND_VERT` se lit « premier plan SPL_PLAN, fond
; vert », la ou un `fcb $2F` ne dit rien du tout.
SPL_PLAN   equ SPL_WHITE+SPL_BRIGHT

; Delai du banc, en tours de boucle. Il n'y a pas d'horloge de
; reference ici, on compte des cycles, et la duree reelle depend de
; la frequence E. ATT_TOURS est le seul curseur.
;
; ┌──────────────┬──────────────────────────────────────────────┐
; │ ATT_TOURS    │ duree constatee sur la carte                 │
; ├──────────────┼──────────────────────────────────────────────┤
; │ 600          │ ~2 s  (regle a l'oeil le 30 septembre 2026)  │
; └──────────────┴──────────────────────────────────────────────┘
;
; La valeur est lineaire : doublez-la, l'attente double. C'est
; mesure sur le banc lui-meme (etape 4), et non deduit d'une
; frequence E, qui reste inconnue dans ce depot.
;
; On NE PEUT PAS remplacer ce compte par une attente de vraie
; trame video, contrairement a ce que la periode de 16 ms pourrait
; faire croire : $A120 est un latch en ecriture seule (74HC374), il
; n'est jamais relu, et depuis la V4 il ne porte plus que la page
; (D0-D2) : aucun bit n'y reflete la trame. Lire un indicateur de
; VSYNC ailleurs serait une adresse materielle non verifiee, or le
; banc n'a droit qu'a $A120 et $8000-$9FFF.
ATT_TOURS  equ 600

; ===================================================================
; CE QUI N'EST PLUS ICI
; -------------------------------------------------------------------
; splash_clear, splash_draw et splash_data sont dans splash.asm.
; Ils etaient dans ce fichier jusqu'au 29 septembre 2026, en double
; de bios/splash.asm, et les deux copies divergeaient deja -- c'est
; exactement le piege que AGENTS.md signale pour le banc. Il y a
; maintenant UNE source de rendu, et c'est splash.asm.
;
; Ce fichier garde ce qui est commun a TOUTES les etapes : la palette,
; le delai, et les routines d'ecriture pleine fenetre (ecran_noir,
; splash_bandes) qui servent de reference quand le rendu est en
; cause.
; ===================================================================

; ===================================================================
; prend_la_main - le banc s'approprie la machine
;
; A QUOI CA SERT. Le banc ne fait aucun appel BIOS, mais cela ne veut
; PAS dire que le BIOS est arrete : les vecteurs d'interruption du
; moniteur sont toujours en place, et le banc ne masque IRQ que le
; temps de ses propres routines de remplissage -- chacune finissant
; par un `puls ,cc` qui LES REMET. Pendant `attente`, et pendant le
; `bra fini` final ou l'image est censee etre stable, le gestionnaire
; VSYNC du BIOS tournait donc a 62,5 Hz.
;
; CE QU'IL FAISAIT. handler_IRQ ecrit le caractere ET sa couleur a
; VRAM_PTR (IT.asm, bloc "AFFICHAGE STANDARD"), 8 par trame, et
; reprogramme a chaque fois les registres curseur R14/R15 du 68B45
; depuis ce meme VRAM_PTR. Consequence vue sur la carte le 30
; septembre 2026, etape 4 : un ecran PARFAITEMENT noir sauf UN
; caractere, ligne 3 colonne 49, qui s'effacait partiellement puis
; revenait. Ligne 3 colonne 49 est precisement l'offset 208
; (= 2*80 + 48), c'est-a-dire la position du curseur du moniteur au
; moment du `RUN 0000`. Ce n'etait pas la table de l'etape, ni un
; artefact d'`ecran_noir` : c'etait la sortie texte que le BIOS
; avait encore en file, reappliquee 62,5 fois par seconde. Le
; "revenir" n'est pas un hasard, c'est la cadence de reecriture --
; et le "s'effacer en partie", l'arbitrage avec le 68B45 qui lit la
; meme RAM pendant que le CPU la reecrit.
;
; CE QUE CELA NE FAIT PAS. handler_FIRQ est vide (IT.asm:334, un RTI
; sec). NMI n'est pas masmable, mais handler_NMI ne contient aucune
; reference a la VRAM : il ne remplit que input_buffer et SCAN_CODE.
; IRQ et FIRQ masques, il ne reste donc AUCUN ecrivain concurrent.
;
; Le curseur MATERIEL du 68B45, lui, reste parke a l'ou il etait :
; c'est un registre du 6845, pas de la RAM video, donc hors des deux
; adresses que le banc a le droit de toucher. Il disparaitra du
; moment ou la cellule qu'il souligne aura des attributs noirs --
; ce que garantit `ecran_noir`.
; Detruit : aucun
; ===================================================================
prend_la_main:
        orcc    #%01010000          ; F + I. Volontairement sans `puls` :
                                    ; ce masque ne se rend JAMAIS.
        rts

; ===================================================================
; ecran_noir - efface les caracteres ($8000-$8FFF) ET les couleurs
; ($9000-$9FFF)
; Reproduit ce que laisse sys_ClearScreen (video.asm:250-310) a
; l'ecran, SANS appeler le BIOS. Sert a l'etape 4.
; Detruit : A, B, D, X
; ===================================================================
ecran_noir:
        pshs    d,x,cc
        orcc    #%01010000
        lda     #$00
        sta     VRAM_CTRL
        ldx     #VRAM_BASE
        ldd     #$2020
en_c:
        std     ,x++
        cmpx    #VRAM_END
        bne     en_c

        ; ⚠ LA RAM COULEUR AUSSI. Cette passe manquait, et elle etait
        ; le second bug trouve SUR LA CARTE le 30 septembre 2026 :
        ; l'etape 4 a laisse « un ecran presque noir avec des traces
        ; diverses et variees » -- les attributs du splash, qui
        ; continuaient de colorer le glyphe $20.
        ;
        ; Sans elle, l'ecran n'est noir que la ou le fond valait deja 0.
        ; La bande bleue du titre, le cyan et le visage, si, restaient
        ; visibles, dans le glyphe d'espace. C'est ce que
        ; sys_ClearScreen efface aussi : video.asm:266/278 fait les DEUX
        ; passes, la 4 (caracteres, $2020) et la 5 (couleurs,
        ; char_attribut). Cette routine ne reproduisait donc PAS ce que
        ; laisse sys_ClearScreen, contrairement a ce qu'annoncaient son
        ; commentaire et AGENTS.md.
        ;
        ; Pire : le verificateur AVAIT FIGE LE BUG. ATTENDU attendait
        ; (4096, une seule passe [$20]) -- donc « corriger » ecran_noir
        ; se faisait rejeter par le controle de couverture. Un
        ; verificateur ne peut pas seulement valider le code, il encode
        ; aussi ce qu'il croit etre la specification.
        ;
        ; V4 : la RAM couleurs a sa propre adresse, $9000-$9FFF. Plus de
        ; `lda #$08 / sta VRAM_CTRL` : D3 est ignore par la carte.
        ldx     #VRAM_COL           ; page 0, RAM couleurs
        ldd     #SPL_BLACK          ; $0000 : noir sur noir
en_a:
        std     ,x++
        cmpx    #VRAM_COL_END
        bne     en_a

        ; V4 : plus de `lda #$10` (« mode affichage ») a la fin. Il n'y
        ; a plus de mode : la VRAM revient au 68B45 des que le CPU
        ; cesse d'y acceder.
        puls    d,x,cc
        rts

; ===================================================================
; splash_bandes - remplit toute la fenetre : 'W' partout, attribut
; qui progresse de 1 tous les 16 octets (bandes verticales)
; Detruit : A, B, D, X
; Preserve : U, Y, S, CC
; Les deux boucles se ferment sur X (cmpx #VRAM_END, puis
; cmpx #VRAM_COL_END), jamais sur U : voir le piege 3, `LEAU` ne
; modifie pas Z.
; V4 : caracteres en $8000-$8FFF, attributs en $9000-$9FFF.
; ===================================================================
splash_bandes:
        pshs    d,x,u,cc
        orcc    #%01010000
        lda     #$00                ; page 0 (D0-D2 ; D3-D5 ignores en V4)
        sta     VRAM_CTRL
        ; Les deux charges sont HORS de la boucle : `lda #'W'` et
        ; `ldb #'W'` valent tous deux $57 (`86 57` et `C6 57`), donc
        ; D = $5757 et la fenetre se remplit de 'W'. Ne pas ecrire
        ; `ldd #'WW'` : lwasm refuse le litteral 8 bits.
        lda     #'W'
        ldb     #'W'
        ldx     #VRAM_BASE
sb_c:
        ; `stb ,x++` ecrit UN octet mais avance X de DEUX : le
        ; post-incrementation vaut toujours 1 registre (2 octets sur
        ; X), `,x+` et `,x++` ne different que par le bit 0 du
        ; postbyte -- lwasm emet $80 et $81. Deux `stb ,x++` a la
        ; suite ecrivaient donc les octets 0, 2, 4... et sautaient
        ; les impairs : l'ecran n'etait rempli qu'un octet sur deux.
        ; C'est `std ,x++` qu'il faut, ca ecrit les DEUX octets.
        ;
        ; ⚠ `std` ecrit A PUIS B. Il faut donc que A vaille 'W' AUSSI.
        ; Un `ldb #'W'` seul laissait A = $00 (venu du `lda #$00` du
        ; choix de page juste au-dessus), donc D = $0057 et
        ; l'ecran devenait $00 $57 $00 $57... : UN glyphe sur deux,
        ; pas 'W' partout. Constate sur la carte le 30 septembre
        ; 2026 -- « W@W@W@W repete en 8 couleurs ». Le remplissage un
        ; octet sur deux etait corrige la veille ; c'est le second
        ; defaut, dans la meme boucle, que ce test vient de reveler.
        ; Ni verifie_remplissage.py ni verifie_rendu.py ne pouvaient le
        ; voir : le premier controle la COUVERTURE (quels offsets
        ; sont ecrits), pas les VALEURS. D'ou l'invariant 3 bis.
        std     ,x++
        cmpx    #VRAM_END
        bne     sb_c

        ldx     #VRAM_COL           ; V4 : RAM couleurs a $9000
        clra
sb_a:
        ; Meme piege d'increment qu'au-dessus : `sta ,x++` ecrit un
        ; seul octet mais avance X de DEUX, donc un attribut sur deux
        ; n'etait jamais ecrit. `leax 1,x` avance d'un seul octet --
        ; et ne pose AUCUN drapeau, ce qui est justement pourquoi la
        ; boucle se ferme sur `cmpx` et pas sur un `bne`.
        ; `anda #$0F` ne sert plus seulement a borner le premier plan
        ; (D0-D2 couleur + D3 luminosite, donc 0..15). Depuis le
        ; changement de carte du 29 septembre 2026, D4-D6 sont la
        ; COULEUR DE FOND : sans ce masquage, A qui monte de 0 a 15
        ; ferait tourner le fond sur huit teintes au lieu de laisser
        ; les bandes sombres sur fond noir. Ne pas "nettoyer" ce `and`.
        anda    #$0F                ; 0..15 = 8 teintes x normal/lumieux
        sta     ,x
        inca
        leax    1,x
        cmpx    #VRAM_COL_END
        bne     sb_a
        puls    d,x,u,cc
        rts

; (`affiche`, qui ecrivait $10 dans VRAM_CTRL pour rendre la VRAM au
; 68B45, a disparu avec la carte V4 : il n'y a plus de mode affichage.
; Aucune etape ne l'appelait.)

; ===================================================================
; attente - delai approxime, sans appel au BIOS
; Detruit : X, U
; ===================================================================
attente:
        ldx     #ATT_TOURS
at1:
        ldu     #1200
at2:
        leau    -1,u
        cmpu    #0                  ; `leau` ne pose pas Z (piege 3)
        bne     at2
        leax    -1,x
        cmpx    #0                  ; `leax` non plus
        bne     at1
        rts

; ===================================================================
; fini - on tourne sur place
; -------------------------------------------------------------------
; Volontaire : si le banc rendait la main, le moniteur ecrirait son
; dump de registres PAR-DESSUS l'image et le test ne servirait a rien.
; RESET pour revenir au moniteur.
; ===================================================================
fini:
        bra     fini
