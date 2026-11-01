; ===================================================================
; UI.INC - Constantes graphiques communes (glyphes + attributs)
; ===================================================================
; Source unique des codes semi-graphiques et des couleurs partagees
; par les applications a fenetres (OSM-VISION, BRIQUES, futures apps).
; Inclus via :   include "../lib/ui.inc"
;
; Ces octets doivent rester identiques a ce que le generateur de
; caracteres contient reellement (font_osm39.bin) : ce sont les codes
; de la PAGE 1, sauf mention contraire. Un changement ici decale tout
; le look des applications sans produire la moindre erreur d'assemblage
; -- d'ou l'interet d'un seul fichier plutot que des recopies
; historiques dans osmvision.asm et games/briques.asm.
;
; Le Makefile de chaque application doit lister ce fichier en
; dependance de l'objet, sinon une modification ne declenche pas le
; reassemblage.
; ===================================================================

; --- Glyphes fenetre (page 1 du generateur) ---
UI_SHADOW       equ $02         ; ombre portee (caractere plein sous la fenetre)
UI_DESKTOP_PAT  equ $03         ; motif du bureau
UI_HORIZ_TOP    equ $20         ; trait horizontal (bord haut)
UI_HORIZ_BOT    equ $21         ; trait horizontal (bord bas)
UI_VERT_L       equ $22         ; bordure verticale gauche
UI_VERT_R       equ $23         ; bordure verticale droite
UI_TOP_L        equ $24         ; coin haut-gauche
UI_TOP_R        equ $25         ; coin haut-droite
UI_BOT_L        equ $26         ; coin bas-gauche
UI_BOT_R        equ $27         ; coin bas-droite
UI_SPACE        equ $00         ; interieur de fenetre, bit 7 de l'attribut a 1 (voir UI_FILL)
UI_FILL         equ UI_SPACE    ; meme octet, nom utilise par les applications de jeu
UI_TITLE_BAR    equ $46         ; trait horizontal avec encoche (barre de titre)
UI_CLOSE_BOX    equ $40         ; case de fermeture (carre creux)
UI_ZOOM_BOX     equ $41         ; case de zoom
; Puits pose sur le bord bas d'une fenetre : la cellule porte DEUX traits,
; en haut le fond du puits (colle a la zone), en bas le bord de la fenetre.
; Parois : UI_VERT_R a gauche de la zone, UI_VERT_L a droite (le trait est
; du cote de la zone) ; en haut, UI_TOP_R / UI_TOP_L sur le filet du titre.
UI_WELL_BOT     equ $28         ; fond du puits + bord bas de la fenetre
UI_WELL_BL      equ $29         ; coin bas-gauche du puits (sous UI_VERT_R)
UI_WELL_BR      equ $2A         ; coin bas-droite du puits (sous UI_VERT_L)
; Icônes (video/glyphes_ui.py, page 1 $1C-$1F : reprogrammer l'EPROM des
; caractères après une modification)
UI_HP           equ $1C         ; haut-parleur
UI_HP_ONDES     equ $1D         ; ... ses ondes : son en marche
UI_HP_MUET      equ $1E         ; ... une croix : son coupé
UI_FLECHE       equ $1F         ; flèche du pointeur (souris)
; Codes renvoyés par scan_keyboard pour les touches spéciales (BIOS,
; bios/keyboard.asm) :
KEY_UP          equ $80
KEY_DOWN        equ $81
KEY_LEFT        equ $82
KEY_RIGHT       equ $83
KEY_HOME        equ $84         ; Début ; Ctrl+Début : KEY_CHOME
KEY_END         equ $85         ; Fin   ; Ctrl+Fin   : KEY_CEND
KEY_PGUP        equ $86
KEY_PGDN        equ $87
KEY_DEL         equ $88         ; Suppr
KEY_INS         equ $89         ; Inser
KEY_CHOME       equ $8A
KEY_CEND        equ $8B

; Page 1 réservée par des applications (ne pas réutiliser) :
;   $2B-$3F, $48-$4E : apps/envahis.asm (envahisseurs, canon, tirs,
;                  explosion, boucliers, soucoupe)
;   $07-$1B, $4F-$7F : apps/minitel.asm (mosaïques du Minitel : $50-$5D
;                  les colonnes de 3 pavés du plein écran, contiguës puis
;                  disjointes ; le reste, les 2 x 3 de la fenêtre 40 x 25),
;                  écrits par tools/minitel/videotex.py --police
;   $1C-$1F : icônes d'OSM-VISION (UI_HP...), video/glyphes_ui.py
;   $88-$FF : apps/glouton.asm (murs, GLOUTON, fantômes, fruits, points),
;                  écrits par video/glyphes_glouton.py qui remet à 0 ce
;                  qu'il n'utilise pas dans la plage
;
; Regle UI_FILL / UI_SPACE : $00 est un blanc en PAGE 1 (attribut bit 7 = 1)
; et un trait horizontal en page 0 ($20 dans ce cas). Donc l'interieur d'une
; fenetre se remplit de $00 avec un attribut couleur de fond, jamais avec
; UI_HORIZ_TOP.

; --- Curseur matériel du 68B45 (registre R10 : lignes 13-15 de la cellule,
;     bits 6-5 = 11 : clignotement au 1/32 des trames ; 01 : caché). Le
;     BIOS démarre à $CD (1/16 : trop rapide, à peine visible). OSM-VISION
;     le cache ; un programme console ou le Minitel le rallume. ---
CURSEUR_VISIBLE equ $6D
CURSEUR_CACHE   equ $2D

; --- Attributs (addition fond + avant-plan : D0-D2 = avant-plan,
;     D3 = intensite, D4-D6 = fond, D7 = page du generateur) ---
COLOR_DESK      equ $97         ; bureau (fond 7, page 1)
COLOR_WIN       equ $8F         ; interieur de fenetre (blanc page 1)
COLOR_TITLE     equ $0F         ; texte de titre (page 0)
COLOR_SHADOW    equ $90         ; ombre portee
COLOR_ICON      equ $8F         ; texte d'icone
COLOR_TEXT      equ $0F         ; texte courant
COLOR_SEL       equ $1F         ; selection (sur fond bleu)
