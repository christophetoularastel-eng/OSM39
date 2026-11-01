    include "hardware.inc"

    import  key_on
    import NEW_CODE
    import  SCAN_CODE,PS2_BYTE
    export keyboard_init,scan_keyboard,kbd_poll,Kbd_Voyants
    import kbd_buf,kbd_tete,kbd_queue,kbd_apres_f0
    import kbd_verr,kbd_led_dem,kbd_led_cpt,kbd_muet
    import PrintHexChar,PrintString
    ;import readkey2_ptr, key2_ptr, key2_buffer
    import e0_received,last_makecode,PS2_BIT_COUNT,PS2_PARITY

shift_key_on    equ %00000001
altgr_key_on    equ %00000010       ; AltGr (E0 11)
ctrl_key_on     equ %00000100
appui_attente   equ %00001000       ; un appui attend son relâchement (voir char_interpreter)
KEY_UP          equ $80
KEY_DOWN        equ $81
KEY_LEFT        equ $82
KEY_RIGHT       equ $83
KEY_HOME        equ $84         ; E0 6C ; avec Ctrl : KEY_CHOME
KEY_END         equ $85         ; E0 69 ; avec Ctrl : KEY_CEND
KEY_PGUP        equ $86         ; E0 7D
KEY_PGDN        equ $87         ; E0 7A
KEY_DEL         equ $88         ; E0 71
KEY_INS         equ $89         ; E0 70
KEY_CHOME       equ $8A
KEY_CEND        equ $8B
SCAN_CODE_LCTRL equ $14
PS2_DATA_BIT    equ %00000001


;**********************************************************
; clavier (Version finale : retour au relâchement, structure saine)
;**********************************************************

;Commande (Hex)	Description	Réponse(s) du clavier
;0xFF	Reset (Réinitialisation)	0xFA (ACK), puis 0xAA (Self-Test Passed)
;0xFE	Resend (Renvoyer)	Le clavier renvoie le dernier octet qu'il a envoyé.
;0xED	Set/Reset Status LEDs (Contrôle des LEDs)	0xFA (ACK), attend ensuite l'octet de paramètre.
;0xEC	Set Alternate Scan Codes (Utiliser un autre jeu de codes)	0xFA (ACK). Remplace le jeu de scan codes par défaut.
;0xEB	Get/Set Scan Code Set (Obtenir/Définir le jeu de scan codes)	0xFA (ACK), puis le clavier envoie le numéro du jeu actuel (0x01, 0x02, ou 0x03).
;0xEA	Set All Keys to Typematic/Make/Break	0xFA (ACK).
;0xE9	Set All Keys to Make/Break	0xFA (ACK).
;0xE8	Set All Keys to Typematic	0xFA (ACK).
;0xE7	Set All Keys to Make	0xFA (ACK).


;0xF3   Set key times

;Bits DD	Valeur	Délai
;%00	0	250 ms
;%01	1	500 ms (Défaut)
;%10	2	750 ms
;%11	3	1000 ms (1 sec)

;Bits RRRRR	HEX	Répétitions par seconde (environ)
;%00000	$00	30.0
;%01000	$08	15.0
;%01111	$0F	10.0
;%10000	$10	9.2
;%10110	$16	6.0
;%11111	$1F	2.0

;Bit	Poids (HEX)	Fonction
;0	$01	Scroll Lock (Arrêt Défilement)
;1	$02	Num Lock (Verr. Num.)
;2	$04	Caps Lock (Verr. Maj.)
;3-7	-	Réservés (doivent être à 0)


    section .code


keyboard_init:
    lda #$03                ;master reset
    sta CR_key
    lda #$dc                ;init 11bit odd RTS=1
    sta CR_key
    rts


; scan_keyboard : attend une touche, A = caractère (jamais 0). Une file
; vidée par un programme qui lit SCAN_CODE lui-même (NEW_CODE remis à 0)
; est périmée : on la jette à l'entrée.
scan_keyboard:
    tst     NEW_CODE
    bne     sk_attente
    lda     kbd_tete
    sta     kbd_queue
    clr     kbd_apres_f0
    clr     e0_received
sk_attente:
    bsr     kbd_poll
    tsta
    beq     sk_attente
    rts

; kb_lire : C = 1 si la file est vide ; sinon C = 0, A = octet suivant.
; NEW_CODE reste à 1 tant que la file n'est pas vide.
kb_lire:
    ldb     kbd_queue
    cmpb    kbd_tete
    beq     kl_vide
    clr     NEW_CODE
    ldx     #kbd_buf
    lda     b,x
    incb
    andb    #15
    stb     kbd_queue
    cmpb    kbd_tete
    beq     kl_ok
    ldb     #1
    stb     NEW_CODE
kl_ok:
    andcc   #$FE
    rts
kl_vide:
    orcc    #$01
    rts

; kbd_poll (service sys_kbd_poll) : traite les octets PS/2 en attente,
; SANS attendre. A = caractère dès qu'une touche est relâchée, A = 0 si
; rien (la touche est rendue au relâchement, comme scan_keyboard). L'état
; (Maj, E0, F0 reçu...) reste en RAM d'un appel à l'autre. Détruit B.
kbd_poll:
    pshs    x,y
scan_loop:
    bsr     kb_lire
    bcc     kp_octet
    clra                        ; plus rien : A = 0
    puls    x,y,pc
kp_octet:
    tst     kbd_apres_f0
    lbne    kp_relache

    ; --- Analyser le code reçu ---
    cmpa    #$E0
    beq     is_e0_code          ; C'est un code étendu
    cmpa    #$F0
    beq     handle_release_code ; C'est un code de relâchement, on va agir !
    cmpa    #$fa                ; acquittement du clavier : rien
    lbeq    scan_loop
    ; --- C'est un code de pression (make code) ---
    ; Est-ce un modificateur ?
    cmpa    #$12           ; SHIFT Gauche
    lbeq    shift_code_on
    cmpa    #$59           ; SHIFT Droit
    lbeq    shift_code_on
    cmpa    #$14 ; CTRL (gauche, ou droite avec E0)
    lbeq     ctrl_code_on
    cmpa    #$11 ; ALT : AltGr avec E0, Alt gauche sinon
    lbeq     alt_code_on
    ; Non, c'est une touche normale (caractère ou flèche). On la mémorise.
    sta     last_makecode
    lda     key_on
    ora     #appui_attente
    sta     key_on
    Bra     scan_loop
    ;bra     char_interpreter

; --- SOUS-ROUTINES DE GESTION ---

is_e0_code:
    lda     #1
    sta     e0_received
    bra     scan_loop       ; On attend le code qui suit E0

handle_release_code:
    ; On a reçu F0. on génère une clock supplémentaire ; le code de la touche
    ; relâchée viendra par la file (au prochain appel s'il n'est pas déjà là).
    ldx #300
wait_loop:
    leax -1,x
    bne wait_loop
    lda #$9C
    sta CR_key
    nop
    nop
    lda #$DC
    sta CR_key
    lda     #1
    sta     kbd_apres_f0
    lbra    scan_loop
kp_relache:
    clr     kbd_apres_f0
    ; On vérifie si c'est le relâchement d'un modificateur

    cmpa    #$12
    lbeq    shift_code_off
    cmpa    #$59
    lbeq    shift_code_off
    cmpa    #$14
    lbeq    ctrl_code_off
    cmpa    #$11
    lbeq    alt_code_off

    ; --- C'est le relâchement d'une touche normale ! ON AGIT. ---
    tst     e0_received     ; S'agissait-il d'une flèche ?
    lbne    handle_extended_return
    ;bra     return_special
    ; Un relâchement ne rend un caractère que s'il est celui de la DERNIÈRE
    ; touche enfoncée, et une fois. Sans cela, un second relâchement sans
    ; nouvel appui (octet mal lu après F0, F0 en double...) rendait encore
    ; last_makecode : MINITEL envoyait les lettres tapées avec Maj en double
    ; (15 oct. 2026). Le bit est retiré avant les comparaisons de key_on.
    cmpa    last_makecode
    lbne    scan_loop
    lda     key_on
    bita    #appui_attente
    lbeq    scan_loop
    anda    #~appui_attente
    sta     key_on
    lda     last_makecode
    cmpa    #$58                ; Verr. Maj : bascule ; le voyant suit (IRQ)
    bne     char_interpreter
    lda     kbd_verr
    eora    #$04
    sta     kbd_verr
    lda     #1
    sta     kbd_led_dem
    lbra    scan_loop
char_interpreter:
    lda     key_on
    bita    #altgr_key_on
    lbne    use_altgr_table
    cmpa    #$04
    beq     use_ctrl_table
    cmpa    #$01
    beq     use_shift_table
    ldy     #tableascii
    bra     do_lookup
use_ctrl_table:
    ldy     #tableasciictrl
    bra do_lookup
use_shift_table:
    ldy     #tableasciishift
do_lookup:
    lda     last_makecode ; On prend le code de la touche qui avait été ENFONCÉE
    lda     a,y           ; On cherche le caractère dans la table
    cmpy    #tableasciictrl     ; avec Ctrl : pas de Verr. Maj
    beq     dl_fin
    ldb     kbd_verr
    bitb    #$04
    beq     dl_fin
    bsr     Inverse_Casse
dl_fin:
    puls    x,y,pc    ; Et on retourne !

; Inverse_Casse : A = caractère (Latin-1, comme les tables). Verr. Maj
; inverse la casse des LETTRES : a-z <-> A-Z, et de $E0-$FE (é è à ç ù...)
; <-> $C0-$DE, sauf ÷ ($F7) et × ($D7). Le reste (chiffres, ponctuation,
; la rangée é & " ' du haut) ne change pas. Préserve B.
Inverse_Casse:
    cmpa    #'A'
    blo     ic_fin
    cmpa    #'Z'
    bls     ic_vers_min
    cmpa    #'a'
    blo     ic_fin
    cmpa    #'z'
    bls     ic_vers_maj
    cmpa    #$C0
    blo     ic_fin
    cmpa    #$D7
    beq     ic_fin
    cmpa    #$DE
    bls     ic_vers_min
    cmpa    #$E0
    blo     ic_fin
    cmpa    #$F7
    beq     ic_fin
    cmpa    #$FE
    bhi     ic_fin
ic_vers_maj:
    suba    #$20
    rts
ic_vers_min:
    adda    #$20
ic_fin:
    rts

; Kbd_Voyants : appelée par l'IRQ du VSYNC (IRQ masquées, CR_key = $5C).
; Une demande de kbd_poll : $ED tout de suite, l'octet des voyants deux
; trames plus tard (le clavier a répondu $FA entre-temps). Détruit A, B, X.
Kbd_Voyants:
    tst     kbd_muet
    beq     kv_etat
    dec     kbd_muet
kv_etat:
    lda     kbd_led_cpt
    beq     kv_demande
    deca
    sta     kbd_led_cpt
    bne     kv_fin
    lda     kbd_verr
    anda    #$07
    bra     Kbd_Envoie
kv_demande:
    tst     kbd_led_dem
    beq     kv_fin
    clr     kbd_led_dem
    lda     #2
    sta     kbd_led_cpt
    lda     #$ED
    bra     Kbd_Envoie
kv_fin:
    rts

; Kbd_Envoie : A = octet pour le clavier (PS/2, hôte -> clavier). TxD est
; sur DATA et TxC sur CLOCK : l'octet attend dans TDR ; RTS bas tient
; CLOCK à 0 (D1) et, à ce front, le 6850 sort son bit de start (DATA à 0) ;
; ~200 µs plus tard RTS remonte : le clavier voit la demande et cadence
; les 11 bits (8 + parité impaire + stop : le format de CR_key), en
; lisant chaque bit au front montant. Essayé sur la machine le 31 oct.
; 2026 (voyant Verr. Maj). Détruit A, B, X.
Kbd_Envoie:
    ldx     #200
ke_tdre:
    ldb     SR_key
    bitb    #$02
    bne     ke_pret
    leax    -1,x
    bne     ke_tdre
    rts                         ; émetteur occupé : tant pis
ke_pret:
    sta     TDR_key
    lda     #$1C                ; RTS bas (RIE = 0) : CLOCK tenue à 0
    sta     CR_key
    ldx     #60                 ; ~200 µs (100 au moins)
ke_att:
    leax    -1,x
    bne     ke_att
    lda     #$5C                ; RTS haut : CLOCK relâchée
    sta     CR_key
    lda     #4
    sta     kbd_muet
    rts

; AltGr : table courte de paires (code, caractère), terminée par 0.
; Une touche absente de la table est ignorée.
use_altgr_table:
    ldy     #tablealtgr
    ldb     last_makecode
altgr_loop:
    lda     ,y
    beq     altgr_none
    cmpb    ,y
    beq     altgr_found
    leay    2,y
    bra     altgr_loop
altgr_found:
    lda     1,y
    puls    x,y,pc
altgr_none:
    lbra    scan_loop

handle_extended_return:

    clr     e0_received   ; On consomme le flag E0
    ;lda     last_makecode ; Quelle flèche avait été enfoncée ?
    cmpa    #$75       ; Flèche HAUT
    beq     return_keyup
    cmpa    #$72       ; Flèche BAS
    beq     return_keydown
    cmpa    #$6B       ; Flèche GAUCHE
    beq     return_keyleft
    cmpa    #$74       ; Flèche DROITE
    beq     return_keyright
    cmpa    #$4A       ; / du pavé numérique
    beq     return_kpslash
    cmpa    #$6C       ; Début
    beq     return_home
    cmpa    #$69       ; Fin
    beq     return_end
    cmpa    #$7D       ; Page précédente
    beq     return_pgup
    cmpa    #$7A       ; Page suivante
    beq     return_pgdn
    cmpa    #$71       ; Suppr
    beq     return_del
    cmpa    #$70       ; Inser
    beq     return_ins
    cmpa    #$5A       ; Entrée du pavé numérique
    beq     return_kpenter
    lbra     scan_loop       ; Autre code E0, on ignore

shift_code_on:

    lda     key_on
    ora     #shift_key_on
    sta     key_on
    clr     e0_received     ; E0 14 (Ctrl droit) : le préfixe est consommé
    lbra     scan_loop
shift_code_off:

    lda     key_on
    anda    #~shift_key_on
    sta     key_on
    clr     e0_received     ; E0 14 (Ctrl droit) : le préfixe est consommé
    lbra     scan_loop
ctrl_code_on:

    lda     key_on
    ora     #ctrl_key_on
    sta     key_on
    clr     e0_received     ; E0 14 (Ctrl droit) : le préfixe est consommé
    lbra     scan_loop
ctrl_code_off:

    lda     key_on
    anda    #~ctrl_key_on
    sta     key_on
    clr     e0_received     ; E0 14 (Ctrl droit) : le préfixe est consommé
    lbra     scan_loop

return_keyup:   lda #KEY_UP
                bra return_special
return_keydown: lda #KEY_DOWN
                bra return_special
return_keyleft: lda #KEY_LEFT
                bra return_special
return_keyright:lda #KEY_RIGHT
                bra return_special
return_kpslash: lda #'/'
                bra return_special
return_home:    lda #KEY_HOME
                bra return_ctrlmod
return_end:     lda #KEY_END
return_ctrlmod: ldb key_on          ; avec Ctrl : Début / Fin du texte
                bitb #ctrl_key_on
                beq return_special
                adda #KEY_CHOME-KEY_HOME
                bra return_special
return_pgup:    lda #KEY_PGUP
                bra return_special
return_pgdn:    lda #KEY_PGDN
                bra return_special
return_del:     lda #KEY_DEL
                bra return_special
return_ins:     lda #KEY_INS
                bra return_special
return_kpenter: lda #$0d
return_special:

    puls    x,y,pc





; Alt : seul AltGr (préfixe E0) compte ; l'Alt gauche est ignoré.
alt_code_on:
    tst     e0_received
    beq     alt_left
    lda     key_on
    ora     #altgr_key_on
    sta     key_on
alt_left:
    clr     e0_received
    lbra    scan_loop
alt_code_off:
    lda     key_on
    anda    #~altgr_key_on
    sta     key_on
    clr     e0_received
    lbra    scan_loop

; AltGr sur clavier AZERTY : (code de la touche, caractère)
tablealtgr:
            FCB $1E,$7E     ; é 2 -> ~
            FCB $26,$23     ; " 3 -> #
            FCB $25,$7B     ; ' 4 -> {
            FCB $2E,$5B     ; ( 5 -> [
            FCB $36,$7C     ; - 6 -> |
            FCB $3D,$60     ; è 7 -> `
            FCB $3E,$5C     ; _ 8 -> \
            FCB $46,$5E     ; ç 9 -> ^
            FCB $45,$40     ; à 0 -> @
            FCB $4E,$5D     ; ) ° -> ]
            FCB $55,$7D     ; = + -> }
            FCB 0

tableascii: ;    0   1   2   3   4   5   6   7   8   9   A   B   C   D   E   F
            FCB $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$09,$00,$00 ;0
            FCB $00,$00,$7f,$00,$00,'a','&',$00,$00,$00,'w','s','q','z',$e9,$00 ;1
            FCB $00,'c','x','d','e',''','"',$00,$00,' ','v','f','t','r','(',$00 ;2
            FCB $00,'n','b','h','g','y','-',$00,$00,$00,',','j','u',$e8,'_',$00 ;3
            FCB $00,';','k','i','o',$e0,$e7,$00,$00,':','!','l','m','p',')',$00 ;4
            FCB $00,$00,$f9,'^',$00,'=',$00,$00,$00,$00,$0d,'$',$00,'*',$00,$00 ;5
            FCB $00,'<',$00,$00,$00,$00,$08,$00,$00,'1',$00,'4','7',$00,$00,$00 ;6
            FCB '0','.','2','5','6','8',$1b,$00,$00,'+','3','-','*','9',$00,$00 ;7
tableasciishift:
            FCB $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$09,$00,$00 ;0
            FCB $00,$00,$00,$00,$00,'A','1',$00,$00,$00,'W','S','Q','Z','2',$00 ;1
            FCB $00,'C','X','D','E','4','3',$00,$00,' ','V','F','T','R','5',$00 ;2
            FCB $00,'N','B','H','G','Y','6',$00,$00,$00,'?','J','U','7','8',$00 ;3
            FCB $00,'.','K','I','O','0','9',$00,$00,'/',$a7,'L','M','P',$b0,$00 ;4
            FCB $00,$00,'%',$A8,$00,'+',$00,$00,$00,$00,$0d,$a3,$00,$b5,$00,$00 ;5
            FCB $00,'>',$00,$00,$00,$00,$08,$00,$00,'1',$00,'4','7',$00,$00,$00 ;6
            FCB '0','.','2','5','6','8',$1b,$00,$00,'+','3','-','*','9',$00,$00 ;7
tableasciictrl:
            FCB $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00 ;0
            FCB $00,$00,$00,$00,$00,$01,$00,$00,$00,$00,$17,$13,$11,$1A,$00,$00 ;1
            FCB $00,$03,$18,$04,$05,$00,$00,$00,$00,$00,$16,$06,$14,$12,$00,$00 ;2
            FCB $00,$0e,$02,$08,$07,$19,$00,$00,$00,$00,$00,$0a,$15,$00,$00,$00 ;3
            FCB $00,$00,$0b,$09,$0f,$00,$00,$00,$00,$00,$00,$0c,$0d,$10,$00,$00 ;4
            FCB $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00 ;5
            FCB $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00 ;6
            FCB $00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00,$00 ;7
        END
