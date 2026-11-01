; ===================================================================
; test/splash_ecran.inc - le CONTENU de l'ecran du splash
; -------------------------------------------------------------------
; C'est un INCLUDE comme splash.asm : ni `section`, ni `export`, ni
; `end`. Il separe le CODE du rendu de son CONTENU, et la separation
; n'est pas cosmetique :
;
;   splash.asm      splash_clear + splash_draw  (620 octets de code)
;   splash_ecran.inc la table de reference      (480 octets de donnees)
;
; Les etapes 2 et 5 ont leur PROPRE table (table_rendu, table_fond) et
; n'incluent donc pas celle-ci. Sans cette separation, elles
; embarqueraient 480 octets qu'elles n'affichent jamais -- spends sur
; la ligne serie, ou chaque octet est une occasion de corrompre le
; transfert (voir les 128 octets en vol dans le Makefile). Les
; etapes 3 et 4, elles, l'incluent.
;
; Le nom `splash_data` n'est donc PAS une convention du banc : c'est
; simplement le nom de CE splash. Chaque etape passe a
; verifie_rendu.py le nom de la table qu'elle veut voir rendue.
;
; Fenetre 80 x 25. Le logo occupe les colonnes 48 a 71, lignes 4 a 16.
; Les textes sont a gauche, colonne 3.
;
; Le logo est dessine en entier dans SPL_CASE, puis le visage est
; REDESSINE par-dessus dans SPL_FACE / SPL_PUPIL. C'est possible
; parce que la RAM couleur et la RAM caracteres sont deux RAM
; distinctes (carte V4 : $8000-$8FFF et $9000-$9FFF) : reecrire le
; meme offset avec un autre attribut ne fissure pas l'image.
;
; Comme D4-D6 sont maintenant le FOND (carto.txt:74) et non plus des
; bits de clignotement, on peut poser un fond par segment. Le cadre
; du logo est en Cyan sur fond noir ; le bandeau de titre porte un
; fond bleu pour montrer que les deux champs sont bien independants
; -- c'est ce que l'etape 3 doit rendre lisible a l'oeil.
; ===================================================================
splash_data:
; --- Logo : le cadre, en une seule couleur ---
        fdb  4,48
        fcb  SPL_CASE
        fcn  " .--------------------. "
        fdb  5,48
        fcb  SPL_CASE
        fcn  " /   o           o    / "
        fdb  6,48
        fcb  SPL_CASE
        fcn  " /                    / "
        fdb  7,48
        fcb  SPL_CASE
        fcn  " |       .----.       | "
        fdb  8,48
        fcb  SPL_CASE
        fcn  " |      (  ..  )      | "
        fdb  9,48
        fcb  SPL_CASE
        fcn  " |       (____)       | "
        fdb  10,48
        fcb  SPL_CASE
        fcn  " |        \  /        | "
        fdb  11,48
        fcb  SPL_CASE
        fcn  " |         \/         | "
        fdb  12,48
        fcb  SPL_CASE
        fcn  " |         /\         | "
        fdb  13,48
        fcb  SPL_CASE
        fcn  " |        /  \        | "
        fdb  14,48
        fcb  SPL_CASE
        fcn  " \____________________/ "
        fdb  15,48
        fcb  SPL_CASE
        fcn  "        ________        "
        fdb  16,48
        fcb  SPL_CASE
        fcn  "       |________|       "

; --- Le visage, redessine par-dessus ---
        fdb  5,53
        fcb  SPL_FACE              ; oeil gauche
        fcn  "o"
        fdb  5,65
        fcb  SPL_FACE              ; oeil droit
        fcn  "o"
        fdb  7,57
        fcb  SPL_FACE              ; arc superieur du sourire
        fcn  ".----."
        fdb  8,56
        fcb  SPL_FACE
        fcn  "(  ..  )"
        fdb  8,58
        fcb  SPL_PUPIL             ; les deux pupilles
        fcn  ".."
        fdb  9,57
        fcb  SPL_FACE
        fcn  "(____)"
        fdb  10,58
        fcb  SPL_FACE
        fcn  "\  /"
        fdb  11,59
        fcb  SPL_FACE
        fcn  "\/"
        fdb  12,59
        fcb  SPL_FACE
        fcn  "/\"
        fdb  13,58
        fcb  SPL_FACE
        fcn  "/  \"

; --- Textes, a gauche ---
; Le bandeau de titre est le segment qui porte un FOND non noir :
; c'est la seule preuve a l'oeil que D4-D6 pilotent le fond et plus le
; clignotement. Si la carte n'a pas ete cablee comme carto.txt le
; dit, c'est ici qu'on le voit.
        fdb  6,3
        fcb  SPL_TITLE+SPL_FOND_BLEU
        fcn  "OSM39 V2"
        fdb  9,3
        fcb  SPL_NAME
        fcn  "Christophe"
        fdb  12,3
        fcb  SPL_SUB
        fcn  "FOSS 6809-HD6309"

        fdb  $00FF,$0000            ; fin de la table
        fcb  $00
