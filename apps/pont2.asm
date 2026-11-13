; ===================================================================
; PONT2.ASM - Module de démonstration de la passerelle (bios/farcall.asm)
; ===================================================================
; Chargé en page 2, $0000, par apps/pont.asm (FS_LoadFile, A = 2).
; Un module de page commence par sa TABLE de fonctions (FDB) en $0000 :
; on l'appelle par FAR_CALLN, A = page, B = numéro de la fonction.
; Depuis cette page, on voit : le module lui-même ($0000-$7FFF), la RAM
; système, la VRAM ($8000-$9FFF), l'EPROM. Pas le programme appelant.
; ===================================================================
    include "../bios/hardware.inc"

    section .code

Module_Table:                   ; offset 0 (vérifié par apps/Makefile)
    FDB     Somme               ; 0 : Y = n -> D = 1 + 2 + ... + n
    FDB     Imbrique            ; 1 : -> B = la page vue par PONT3
    FDB     Ecrit               ; 2 : Y = adresse VRAM -> le message y est écrit

Somme:
    LDD     #0
S_Loop:
    CMPY    #0
    BEQ     S_Fin
    PSHS    Y
    ADDD    ,S++
    LEAY    -1,Y
    BRA     S_Loop
S_Fin:
    ANDCC   #%11111110
    RTS

; Une page en appelle une autre : la passerelle s'imbrique.
Imbrique:
    LDA     #3
    LDB     #0
    JMP     FAR_CALLN           ; son RTS revient directement à l'appelant

; La VRAM est en mémoire commune : visible depuis n'importe quelle page.
; (L'appelant est entre vis_Sync_Begin et vis_Sync_End.)
Ecrit:
    LDX     #Message
E_Loop:
    LDA     ,X+
    BEQ     E_Fin
    STA     ,Y                  ; caractère
    LDA     #$0E                ; jaune, page 0 du générateur
    STA     VRAM_COL_OFS,Y      ; sa couleur (V4 : 4 Ko plus haut ; mono : l'octet suivant)
    LEAY    VRAM_PAS,Y
    BRA     E_Loop
E_Fin:
    ANDCC   #%11111110
    RTS

Message:        FCN "Bonjour depuis la page 2 !"
