; ===================================================================
; PONT3.ASM - Module de démonstration de la passerelle, page 3, $0000
; ===================================================================
; Appelé par PONT2 (appel imbriqué) : rend la page où il s'exécute.
; ===================================================================
    include "../bios/hardware.inc"

    section .code

Module_Table:                   ; offset 0 (vérifié par apps/Makefile)
    FDB     Ou_Suis_Je          ; 0 : -> B = current_page (3 attendu)

Ou_Suis_Je:
    LDB     current_page
    ANDCC   #%11111110
    RTS
