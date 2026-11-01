; ===================================================================
; test/stage5_fond.asm - ETAPE 5 : LA COULEUR DE FOND
; -------------------------------------------------------------------
; Modification MATERIELLE du 29 septembre 2026 (video/carto.txt:71-75) :
; l'octet d'attribut porte maintenant DEUX couleurs.
;     D0-D2  couleur du caractere (premier plan)
;     D3     luminosite du caractere
;     D4-D6  couleur de FOND
;     D7     page du generateur de caracteres (8x16)
; Avant, D4-D6 portaient le clignotement, la complementation a chaque
; VSYNC et l'inversion des bits. Ces trois fonctions ont DISPARU de
; l'octet d'attribut.
;
; C'est la SEULE etape qui prouve que la nouvelle fonction de la carte
; fonctionne. Elle ecrit huit bandes, une par valeur de fond possible
; (0 a 7), en utilisant splash_draw comme toutes les etapes de rendu --
; donc verifie_rendu.py controle aussi celle-ci, automatiquement, avant
; le moindre octet envoye sur la ligne serie.
;
; CE QU'ON DOIT VOIR, DANS CET ORDRE
; -------------------------------------------------------------------
; C'est un test, pas une decoration :
;   - huit bandes de FOND differentes : D4-D6 pilotent bien une couleur
;     de fond ;
;   - le caractere lisible DANS chaque bande : la couleur de fond
;     n'efface pas le premier plan. Si l'octet gardait l'ancien
;     cablage, D6 "inverse les bits du caractere" et le texte
;     disparaitrait sur les bandes ou ce bit tombe a 1 ;
;   - RIEN NE CLIGNOTE. C'est le symptome le plus concluant d'un
;     cablage resté ancien : D4 signifiait "clignoter" et D5
;     "complementer a chaque VSYNC". Un ecran qui clignote, ou dont les
;     bandes s'inversent d'une trame a l'autre, ne peut pas etre la
;     carte decrite par carto.txt ;
;   - le premier plan ne change JAMAIS d'une bande a l'autre : c'est
;     constant dans la table, donc c'est le fond qui bouge.
;
; CE QUE CETTE ETAPE NE PROUVE PAS
; -------------------------------------------------------------------
; Le fond vaut 0 a 7 et n'a PAS de bit de luminosite : D3 appartient au
; caractere (carto.txt:73). Il n'existe donc pas de fond « lumineux »,
; et cette etape n'en pretend rien.
;
; La correspondance numero -> teinte REELLE n'est documentee dans
; AUCUN fichier du depot (ordre suppose MC6847, a confirmer a l'oeil).
; Comme le premier plan est constant, la bande dont le fond tombe
; dans la meme teinte que ce premier plan sera peu lisible -- c'est
; attendu, et c'est meme utile : cela revele la palette reelle.
;
; D7 (page du generateur de caracteres) n'est pas teste ici : on n'a
; aucun moyen de savoir ce que contient la page 1, donc la moindre
; difference observee serait inexpliquable.
;
; ATTENTION A L'ORDRE DES INCLUDE
;
; `start` DOIT etre la premiere chose de la section .code, parce que
; le moniteur fait `JSR $0000` (run_cmd fait `JSR ,X` avec X = 0). Les
; includes viennent APRES : sinon la routine incluse se retrouve a
; $0000, le banc demarre au milieu d'elle et `RUN 0000` n'execute
; rien. Le Makefile le verifie et fait echouer le build.
; ===================================================================
        section .code

start:
        jsr     prend_la_main   ; IRQ+FIRQ masques POUR DE BON
        jsr     splash_clear
        ldx     #table_fond
        jsr     splash_draw
        jmp     fini               ; jmp 16 bits : avec huit bandes
                                      ; pleines, l'ecart a `fini` depasse
                                      ; les 127 d'un bra

        include "common.inc"
        include "splash.asm"

; ===================================================================
; table_fond - les huit bandes
; -------------------------------------------------------------------
; Le nom `table_fond` et non `splash_data` : splash.asm declare deja
; le splash de reference sous ce nom, et cette etape a la sienne. Le
; nom de la table a rendre est un ARGUMENT de verifie_rendu.py (que le
; Makefile passe), donc cette etape est verifiee au meme titre que les
; etapes 2, 3 et 4, sans code supplementaire.
;
; Premier plan CONSTANT : SPL_PLAN (= SPL_WHITE+SPL_BRIGHT). Seul le fond
; change. Les bandes font les 80 colonnes : une bande pleine largeur se
; distingue sans ambiguite d'une colonne qu'on aurait simplement oubliee
; de peindre. Elles sont espacees de trois lignes pour rester nettement
; separees, et la derniere (ligne 22) laisse de la place en dessous.
;
; DEUX INTERDITS DANS LES fcb, lwasm 4.24 :
;   - AUCUNE espace apres la virgule : `fcb 1, 2, 3` est refuse, et le
;     message designe le MAUVAIS argument ;
;   - AUCUN espace autour du `+` : `fcb A + B` n'evalue PAS le `+`, il
;     rend A tout court, sans aucun diagnostic. C'est ce qui rendait la
;     palette des fonds fausse (voir common.inc) ; les huit attributs
;     sortaient $0F $10 $11 $12 $13 $14 $15 $16 au lieu de
;     $0F $1F $2F $3F $4F $5F $6F $7F, donc huit bandes qui ne
;     changeaient que le premier plan.
; ===================================================================
table_fond:
        fdb  1,0
        fcb  SPL_PLAN+SPL_FOND_NOIR
        fcn  "################################################################################"
        fdb  4,0
        fcb  SPL_PLAN+SPL_FOND_BLEU
        fcn  "################################################################################"
        fdb  7,0
        fcb  SPL_PLAN+SPL_FOND_VERT
        fcn  "################################################################################"
        fdb  10,0
        fcb  SPL_PLAN+SPL_FOND_CYAN
        fcn  "################################################################################"
        fdb  13,0
        fcb  SPL_PLAN+SPL_FOND_ROUGE
        fcn  "################################################################################"
        fdb  16,0
        fcb  SPL_PLAN+SPL_FOND_MAG
        fcn  "################################################################################"
        fdb  19,0
        fcb  SPL_PLAN+SPL_FOND_JAUNE
        fcn  "################################################################################"
        fdb  22,0
        fcb  SPL_PLAN+SPL_FOND_GRIS
        fcn  "################################################################################"

        fdb  $00FF,$0000            ; fin de la table
        fcb  $00

        end
