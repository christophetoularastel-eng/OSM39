; ===================================================================
; VIS.INC - Services d'OSM-VISION pour les applications fenetrees
; ===================================================================
; Une application lancee par OSM-VISION (attribut 'a') tourne dans SA
; page (page 1, liee a $0000 ; OSM-VISION reste en page 0 et l'appelle par
; FAR_CALL). Elle ne voit donc pas OSM-VISION : elle emporte sa copie des
; services, lib/vision.asm, et les appelle par leur table :
;
;       include "../lib/vis.inc"        ; (en tete : definitions)
;       ...
;       JSR     [VIS_TABLE+vis_Window]
;       ...
;       include "../lib/str.asm"        ; (apres le point d'entree)
;       include "../lib/vision.asm"
;
; L'ordre de la table est controle a l'assemblage (IFNE/ERROR dans
; lib/vision.asm). VIS_COUNT_ADR et le controle de version des
; applications restent valables, mais passent toujours : l'application et
; ses services sont assembles ensemble.
; Ecran : 80 x 25, A = colonne, B = ligne. Attributs et glyphes :
; lib/ui.inc. V4 : caracteres en $8000-$8FFF, couleurs en $9000-$9FFF
; (meme cellule + VRAM_COL_OFS) ; vis_Sync_Begin pose la page video 0.
; Toute ecriture VRAM se fait ENTRE vis_Sync_Begin et vis_Sync_End
; (retour de trame, IRQ masquees), sauf mention contraire.
; ===================================================================

; VIS_COUNT_ADR (FCB : nombre d'entrees) et VIS_TABLE (FDB : premiere
; entree) sont des ETIQUETTES de lib/vision.asm (pas des EQU : une
; reference avant ordinaire, sans passe de plus pour l'ASM de la carte).

; --- vis_Sync_Begin : attend le VSYNC (IRQ ACTIVES a l'entree), puis
;     masque les IRQ. Ensuite : acces CPU a la VRAM. Preserve tous
;     les registres (sauf CC). ---
vis_Sync_Begin  equ 0

; --- vis_Sync_End : reactive les IRQ (V4 : la VRAM revient seule au
;     68B45, plus de « mode affichage » $10). Detruit A. ---
vis_Sync_End    equ 2

; --- vis_Window : fenetre au style OSM-VISION, ombre comprise.
;     Entree : A = colonne, B = ligne, W = largeur*256+hauteur
;              (ombre EN PLUS : une colonne a droite, une ligne dessous),
;              Y = titre (0 final, centre) ou 0 = cadre simple sans titre.
;     Entre Sync_Begin et Sync_End : la routine rend elle-meme la main
;     au 68B45 par petits lots (un VSYNC par lot), donc elle peut
;     durer plusieurs trames. Preserve A, B, X, Y, U ; detruit W. ---
vis_Window      equ 4

; --- vis_Text : texte de la page 0 du generateur : ASCII, et Latin-1
;     ($A0-$FF, les accents du clavier) traduit en CP437 en dessinant
;     (lib/latin_cp437.inc).
;     Entree : A = colonne, B = ligne, X = chaine (0 final),
;              E = attribut (bit 7 a 0 : page 0).
;     Ecrit les caracteres puis leurs attributs. Ne fait pas de VSYNC :
;     a l'appelant de rester dans sa fenetre de temps.
;     Detruit A, B, X, Y, W. ---
vis_Text        equ 6

; --- vis_MsgBox : boite de message modale, au centre de l'ecran.
;     Entree : X = texte, Y = titre (0 final). IRQ ACTIVES, HORS de
;     Sync_Begin/Sync_End (elle se synchronise seule). Joue le son
;     d'erreur, attend Entree / Echap / Espace, puis restaure ce qu'il
;     y avait dessous. Detruit A, B, X, Y, W. ---
vis_MsgBox      equ 8

; --- vis_Sound : joue une partition (format : lib/snd.inc), SAUF si
;     l'utilisateur a coupe le son dans OSM-VISION (touche M).
;     Entree : X = partition. Preserve A, B, X.
;     La partition doit rester en memoire tant qu'elle joue : OSM-VISION
;     coupe le son au retour de l'application. ---
vis_Sound       equ 10

; --- vis_Sound_Stop : silence immediat, meme son coupe.
;     Preserve A, B, X. ---
vis_Sound_Stop  equ 12

; --- vis_Fill : remplit un rectangle d'un caractere et d'un attribut.
;     Entree : A = colonne, B = ligne, W = largeur*256+hauteur,
;              Y = caractere*256+attribut.
;     Largeur ou hauteur nulle : rien. Aucun controle de bord : a
;     l'appelant de rester dans l'ecran (colonne+largeur <= 80).
;     Entre Sync_Begin et Sync_End ; rend la main au 68B45 par lots,
;     comme vis_Window. Caracteres d'abord, attributs ensuite.
;     Preserve A, B, X, Y, U ; detruit W. ---
vis_Fill        equ 14

; --- vis_PutCell : une cellule.
;     Entree : A = colonne, B = ligne, E = caractere, F = attribut.
;     Entre Sync_Begin et Sync_End. Preserve tous les registres. ---
vis_PutCell     equ 16

; --- vis_Rect_Save : copie un rectangle de l'ecran (les deux plans)
;     dans un tampon de l'APPLICATION, avant d'y dessiner un menu ou une
;     boite. Entree : A = colonne, B = ligne, W = largeur*256+hauteur
;     (ombre comprise : +1 et +1 pour une vis_Window de meme taille),
;     X = tampon de largeur*hauteur*2 octets (caracteres puis
;     attributs). Le tampon d'OSM-VISION (vis_MsgBox) n'est pas
;     touche : une boite de message par-dessus ne l'ecrase pas.
;     Entre Sync_Begin et Sync_End, par lots synchronises sur le VSYNC.
;     Rectangle vide : rien. Preserve A, B, X, Y, U ; detruit W. ---
vis_Rect_Save   equ 18

; --- vis_Rect_Restore : remet le rectangle sauve par vis_Rect_Save.
;     Memes registres, meme tampon. Le rectangle passe d'abord en noir
;     sur noir, puis caracteres, puis couleurs : rien ne clignote.
;     Preserve A, B, X, Y, U ; detruit W. ---
vis_Rect_Restore equ 20

; --- vis_Input : ligne de saisie modale (fond COLOR_SEL, curseur '_').
;     Entree : A = colonne, B = ligne, X = tampon (texte termine par 0,
;              eventuellement prerempli ; place pour longueur max + 1),
;              E = longueur max (1..78), F = options INP_*,
;              Y = crochet appele apres chaque modification, ou 0.
;     Touches : imprimables ($20-$7E, et Latin-1 $A0-$FF sauf avec
;     INP_MAJ ; filtrees par F), Retour arriere,
;     Entree, Echap. Le champ occupe longueur max + 1 colonnes.
;     Sortie : C = 1 si Echap ; sinon C = 0 et A = touche de sortie
;              ($0D, ou la touche de controle si INP_CTRL).
;              B = longueur du texte. Le tampon reste termine par 0.
;     IRQ ACTIVES, HORS de Sync_Begin/Sync_End (comme vis_MsgBox).
;     Le crochet est appele ENTRE Sync_Begin et Sync_End et peut
;     detruire A, B, X, Y, U, W (par ex. effacer un message d'erreur).
;     Preserve X, Y, U ; detruit W. Pour reprendre la saisie apres la
;     sortie (erreur a afficher, touche INP_CTRL traitee), rappeler
;     vis_Input avec le meme tampon : le texte est conserve. ---
vis_Input       equ 22

; Options de vis_Input (registre F, a additionner)
INP_MAJ         equ $01         ; minuscules converties en majuscules
INP_SANS_ESPACE equ $02         ; espace refuse (noms de fichiers)
INP_NON_VIDE    equ $04         ; Entree ignoree tant que le texte est vide
INP_CTRL        equ $08         ; rend la main sur une touche de controle
                                ; ($00-$1F hors $08 $0D $1B), A = touche

; --- vis_Prep / vis_Ligne : une ligne de texte longue sans parasites. Le
;     service de texte coûte ~32 cycles par caractère sur la mono : une
;     ligne de 80 dépasse la fenêtre de retour de trame (~1700 cycles
;     utiles). On compose donc la ligne en RAM HORS synchronisation
;     (vis_Prep, autant d'appels qu'on veut : la ligne, puis une case en
;     surbrillance par-dessus), puis on la copie PENDANT (vis_Ligne, TFM,
;     ~500 cycles pour 80 cases).
;   vis_Prep  : A = colonne dans la ligne (0-79), X = chaîne (0 final),
;               E = attribut. Latin-1 traduit en CP437. Détruit D, X.
;   vis_Ligne : A = colonne, B = ligne de l'écran ; copie ce que vis_Prep
;               a composé (de la colonne 0 de la ligne à la plus loin
;               écrite), puis vide la ligne. Entre Sync_Begin et Sync_End
;               (budget de la trame compté, Sync_Yield si besoin).
;               Préserve X, Y, U. ---
vis_Prep        equ 24
vis_Ligne       equ 26

VIS_COUNT       equ 14          ; nombre d'entrees connues par ce fichier
