; ===================================================================
; PONT.ASM - Démonstration de la passerelle entre pages (FAR_CALLN)
; ===================================================================
; Application d'OSM-VISION (modèle apps/mire.asm). Charge deux modules,
; PONT2 en page 2 et PONT3 en page 3 (en $0000, chacun avec sa table de
; fonctions), puis appelle leurs fonctions par la passerelle du BIOS
; (bios/farcall.asm, FAR_CALLN en $FFE3) et affiche ce qu'elles rendent.
; Les modules ne voient ni OSM-VISION ni cette application : seulement
; leur page, la RAM système, la VRAM et l'EPROM.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"
    include "../lib/ui.inc"
    include "../lib/vis.inc"

    export App_Start

VIS_REQUIS      equ (vis_Text/2)+1

WIN_X           equ 10
WIN_Y           equ 5
WIN_W           equ 60
WIN_H           equ 15
TX              equ WIN_X+3
ROW_MSG         equ WIN_Y+7         ; là où PONT2 écrit lui-même
ASCII_0         equ $30             ; lib/str.asm

    section .code

App_Start:
    ANDCC   #%11101111
    LDA     >VIS_COUNT_ADR
    CMPA    #VIS_REQUIS
    BHS     AS_VisOk
    RTS
AS_VisOk:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #WIN_X
    LDB     #WIN_Y
    LDW     #(WIN_W*256)+WIN_H
    LDY     #TxtTitre
    JSR     [VIS_TABLE+vis_Window]
    JSR     [VIS_TABLE+vis_Sync_End]
    ; --- les deux modules, chacun dans sa page, en $0000 ---
    LDA     #2
    LDX     #Nom2
    LDY     #0
    JSR     [table_function_ram+sys_FS_LoadFile]
    LBCS    Erreur
    LDA     #3
    LDX     #Nom3
    LDY     #0
    JSR     [table_function_ram+sys_FS_LoadFile]
    LBCS    Erreur
    LDX     #TxtCharges
    LDB     #WIN_Y+2
    JSR     Show
    ; --- 1. une fonction de la page 2 : D = 1 + ... + 100 ---
    LDA     #2
    LDB     #0
    LDY     #100
    JSR     FAR_CALLN
    PSHS    D
    LDU     #Line
    LDX     #TxtSomme
    JSR     Append
    PULS    D
    JSR     Dec16
    CLR     ,U
    LDX     #Line
    LDB     #WIN_Y+4
    JSR     Show
    ; --- 2. page 2 -> page 3 : B = la page vue là-bas ---
    LDA     #2
    LDB     #1
    JSR     FAR_CALLN
    CLRA
    PSHS    D
    LDU     #Line
    LDX     #TxtImbrique
    JSR     Append
    PULS    D
    JSR     Dec16
    CLR     ,U
    LDX     #Line
    LDB     #WIN_Y+5
    JSR     Show
    ; --- 3. la page 2 écrit elle-même à l'écran ---
    LDX     #TxtEcrit
    LDB     #WIN_Y+6
    JSR     Show
    LDA     #VRAM_LIGNE
    LDB     #ROW_MSG
    MUL
    ADDD    #VRAM_BASE+(TX+2)*VRAM_PAS
    TFR     D,Y
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #2
    LDB     #2
    JSR     FAR_CALLN
    JSR     [VIS_TABLE+vis_Sync_End]
    ; --- 4. et nous voilà revenus en page 0 ---
    LDU     #Line
    LDX     #TxtRetour
    JSR     Append
    CLRA
    LDB     current_page
    JSR     Dec16
    CLR     ,U
    LDX     #Line
    LDB     #WIN_Y+9
    JSR     Show
    LDX     #TxtTouche
    LDB     #WIN_Y+12
    JSR     Show
    BRA     Attente
Erreur:
    LDX     #TxtErreur
    LDB     #WIN_Y+2
    JSR     Show
Attente:
    JSR     [table_function_ram+sys_scan_keyboard]
    CMPA    #0
    BEQ     Attente
    RTS                         ; OSM-VISION restaure l'écran

; X = texte, B = ligne : à TX, attribut COLOR_TEXT.
Show:
    JSR     [VIS_TABLE+vis_Sync_Begin]
    LDA     #TX
    LDE     #COLOR_TEXT
    JSR     [VIS_TABLE+vis_Text]
    JMP     [VIS_TABLE+vis_Sync_End]

; Append / Dec16 : lib/str.asm
    include "../lib/str.asm"

TxtTitre:       FCN " PASSERELLE ENTRE PAGES "
Nom2:           FCC "PONT2          "
Nom3:           FCC "PONT3          "
TxtCharges:     FCN "PONT2 charge en page 2, PONT3 en page 3."
TxtSomme:       FCN "Page 2, fonction 0 : 1 + 2 + ... + 100 = "
TxtImbrique:    FCN "Page 2 -> page 3 (imbrique) : page vue = "
TxtEcrit:       FCN "Page 2, fonction 2, ecrit elle-meme a l'ecran :"
TxtRetour:      FCN "De retour ici, current_page = "
TxtTouche:      FCN "Une touche pour revenir a OSM-VISION."
TxtErreur:      FCN "PONT2 ou PONT3 introuvable sur la carte SD."

NumStarted      rmb 1
DigitCnt        rmb 1
Line            rmb 64

; Les services d'affichage (lib/vis.inc) : l'application tourne dans sa
; propre page et emporte sa copie (OSM-VISION, en page 0, ne se voit pas).
    include "../lib/vision.asm"
