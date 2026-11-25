; ===================================================================
; GRAPHE.ASM - Démonstration du mode graphique (sys_Graphe, 640 x 400)
; Usage: GRAPHE          (une touche pour revenir au texte)
; Charge: page 1, $0000
; ===================================================================
; Ouvre le mode graphique, dessine (cadre, éventail de lignes, cercles,
; disque inversé, rectangles, bandes de couleur, texte en police 8 x 8),
; attend que l'écran ait rattrapé l'image, puis une touche ; GR_FIN rend
; l'écran texte (effacé). Les fonctions : tools/graphe/graphe.py.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

GR_DEBUT    EQU 0
GR_FIN      EQU 1
GR_LIGNE    EQU 3
GR_RECT     EQU 4
GR_CERCLE   EQU 5
GR_DISQUE   EQU 6
GR_CAR      EQU 9
GR_COULEUR  EQU 10
GR_ATTEND   EQU 11

    section .code

Start:
    LDA     #$07                ; blanc sur noir
    LDB     #GR_DEBUT
    JSR     [table_function_ram+sys_Graphe]
    BCC     Dessine
    LDX     #Absent
    JSR     [table_function_ram+sys_PrintString]
    RTS
Dessine:
    LDY     #Ordres             ; fonction, mode, puis 4 mots
Ordre:
    LDB     ,Y
    CMPB    #$FF
    BEQ     Eventail
    LDA     1,Y
    LEAX    2,Y
    JSR     [table_function_ram+sys_Graphe]
    LEAY    10,Y
    BRA     Ordre

; un éventail : du coin bas gauche vers le haut, x de 0 à 639 par 32
Eventail:
    LDD     #0
    STD     Bloc
    LDD     #399
    STD     Bloc+2
    STD     Bloc+6
    LDD     #0
Ev_Ligne:
    STD     Bloc+4
    LDD     #200
    STD     Bloc+6
    LDX     #Bloc
    CLRA
    LDB     #GR_LIGNE
    JSR     [table_function_ram+sys_Graphe]
    LDD     Bloc+4
    ADDD    #32
    CMPD    #640
    BLO     Ev_Ligne

; le texte, rangée 1, à partir de la colonne 2
    LDY     #Titre
    LDD     #2
    STD     Bloc
    LDD     #1
    STD     Bloc+2
Tx_Car:
    LDB     ,Y+
    BEQ     Tx_Fin
    CLRA
    STD     Bloc+4
    LDX     #Bloc
    CLRA
    LDB     #GR_CAR
    JSR     [table_function_ram+sys_Graphe]
    LDD     Bloc
    ADDD    #1
    STD     Bloc
    BRA     Tx_Car
Tx_Fin:
    LDB     #GR_ATTEND
    JSR     [table_function_ram+sys_Graphe]
    JSR     [table_function_ram+sys_scan_keyboard]
    LDB     #GR_FIN
    JSR     [table_function_ram+sys_Graphe]
    RTS

Ordres:
    FCB     GR_COULEUR,$1E      ; rangée 1 : jaune sur bleu
    FDB     0,1,79,1
    FCB     GR_COULEUR,$02      ; bandes : vert, cyan, rouge, magenta
    FDB     0,3,19,24
    FCB     GR_COULEUR,$03
    FDB     20,3,39,24
    FCB     GR_COULEUR,$04
    FDB     40,3,59,24
    FCB     GR_COULEUR,$05
    FDB     60,3,79,24
    FCB     GR_LIGNE,0          ; le cadre
    FDB     0,0,639,0
    FCB     GR_LIGNE,0
    FDB     639,0,639,399
    FCB     GR_LIGNE,0
    FDB     639,399,0,399
    FCB     GR_LIGNE,0
    FDB     0,399,0,0
    FCB     GR_CERCLE,0
    FDB     320,220,150,0
    FCB     GR_CERCLE,0
    FDB     320,220,100,0
    FCB     GR_DISQUE,2         ; inversé : il creuse ce qu'il recouvre
    FDB     320,220,60,0
    FCB     GR_RECT,0
    FDB     40,300,140,360
    FCB     GR_RECT,2
    FDB     90,330,200,390
    FCB     GR_DISQUE,0
    FDB     560,120,40,0
    FCB     $FF

Titre:      FCN     "OSM39 - MODE GRAPHIQUE 640 x 400 - une touche pour revenir"
Absent:     FCN     "GRAPHE : pas de mode graphique (BIOS2 ?)"
Bloc:       RMB     8
