; ===================================================================
; farcall.asm - Passerelle entre les pages de RAM ($0000-$7FFF)
; ===================================================================
; Un gros programme peut répartir son code sur les 4 pages de 32 Ko :
; une fonction d'une autre page s'appelle par la passerelle, qui bascule
; la page, appelle, puis rend la page de l'appelant. La passerelle est en
; EPROM (toujours visible) et la pile en RAM système : rien ne disparaît
; pendant la bascule.
;
; Deux chemins vers les mêmes routines :
;   JSR [table_function_ram+sys_Far_Call]   (ou sys_Far_CallN), comme tout
;                       service du BIOS ;
;   JSR FAR_CALL ($FFE0) / FAR_CALLN ($FFE3) : table de sauts FIXE en EPROM
;                       (section .romjmp, hardware.inc).
;   Far_Call  : A = page (0-3), X = adresse de la fonction
;   Far_CallN : A = page (0-3), B = numéro de la fonction dans la table de
;               la page : FDB f0,f1,... en $0000 de la page (on réassemble
;               une page sans casser ceux qui l'appellent, comme la table
;               vis_ d'OSM-VISION).
;
; Contrat :
;   * l'appelée reçoit B, X, Y, U, W tels quels, et A = sa page ;
;   * l'appelant reçoit D, X, Y, U, W et CC tels que l'appelée les rend
;     (C = la retenue d'erreur de l'appelée) ;
;   * page > 3 : rien n'est appelé, C = 1 ;
;   * current_page suit la bascule : un service du BIOS (FS_LoadFile,
;     FarRead...) appelé depuis l'autre page y revient bien ;
;   * les appels s'imbriquent (une fonction de la page 2 peut en appeler
;     une de la page 3, ou revenir en page 0) : tout est sur la pile.
; Attention : le séquenceur de son (IRQ) lit sa partition dans la page
; visible ; une partition jouée par vis_Sound doit être dans la page où
; l'on reste, ou passer par sys_snd_play (copie en RAM système).
; ===================================================================
    include "hardware.inc"

    export  Far_Call, Far_CallN, Sys_Absent

    section .code

Far_Call:
    cmpa    #4
    bhs     FC_Refus
    pshs    a                   ; page cible
    lda     current_page
    pshs    a                   ; 0,s = page de l'appelant, 1,s = page cible
    lda     1,s
    bsr     Fc_Bascule
    lda     1,s                 ; l'appelée reçoit A = sa page
    jsr     ,x
Fc_Retour:
    pshs    cc,a                ; ce que l'appelée rend (CC à 0,s, A à 1,s)
    lda     2,s                 ; page de l'appelant
    bsr     Fc_Bascule
    puls    cc,a
    leas    2,s                 ; (LEAS ne touche pas CC)
    rts
FC_Refus:
; Aussi la cible des emplacements libres de table_function_rom : un
; programme qui appelle un service absent de cette EPROM reçoit C = 1.
Sys_Absent:
    orcc    #%00000001
    rts

Far_CallN:
    cmpa    #4
    bhs     FC_Refus
    pshs    a
    lda     current_page
    pshs    a
    lda     1,s
    bsr     Fc_Bascule
    ldx     #0                  ; table de la page, maintenant visible
    abx
    abx
    ldx     ,x
    lda     1,s
    jsr     ,x
    bra     Fc_Retour

; A = page : current_page et le latch $A0C0, IRQ et FIRQ masquées entre les
; deux écritures. Préserve tous les registres et CC.
Fc_Bascule:
    pshs    cc
    orcc    #%01010000
    sta     current_page
    sta     pager_reg
    puls    cc,pc

; --- Table de sauts à adresse fixe : n'ajouter qu'à la FIN ---
    section .romjmp
rom_FarCall:    jmp     Far_Call        ; $FFE0
rom_FarCallN:   jmp     Far_CallN       ; $FFE3
