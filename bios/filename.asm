; ===================================================================
; filename.asm - Utilitaires de gestion de noms de fichiers
; ===================================================================

    export strcpy, strlen

    section .code

; Format_Filename_83 : dans osmfs.asm (il résout les chemins de dossiers).

; --- Sous-routine : Convertit le caractère dans A en majuscule ---
Convert_To_Upper:
    cmpa    #'a'
    blo     Is_Not_Lowercase
    cmpa    #'z'
    bhi     Is_Not_Lowercase
    suba    #$20
Is_Not_Lowercase:
    rts

; ===================================================================
; strlen - Calcule la longueur d'une chaîne terminée par $00
; Entrée : X -> Pointeur vers le début de la chaîne
; Sortie : D -> Longueur de la chaîne (16 bits)
; ===================================================================
strlen: pshs y,x
        ldy #0
len_loop:
        tst ,x+
        beq strlen_end
        leay +1,y
        bra len_loop
strlen_end:
        tfr y,d
        puls x,y,pc

; ===================================================================
; strcpy - Copie une chaîne terminée par $00
; Entrée : X -> SOURCE, Y -> DESTINATION
; Sortie : Aucune
; ===================================================================
strcpy:
        pshs d,y,x
strcpy_loop:
        lda ,x+
        sta ,y+
        bne strcpy_loop
        puls   d,y,x,pc
