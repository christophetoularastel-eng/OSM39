        include "hardware.inc"
        include "sysfunc.inc"

        export main

        export PrintChar
        export PrintString
        export PrintHexChar
        export reg_cmd,read_line,Secours
        export PrintHexWord
        export PrintCRLF, ls_cmd
        export  PrintFileName83,Pager,LoadandExec,FarRead,FarWrite
        import  FS_Mount

        import table_function_ram
        import scan_keyboard
        import SCAN_CODE
        import Init_SD_Card

        import SD_Deselect
        import SD_Select
        import SD_ReadBlock
        import SD_BUFFER
        import write_load_ptr
        import read_load_ptr
        import load_buffer
        import write_line_ptr
        import read_line_ptr
        import  input_buffer
        import  write_buffer
        import  g_find_fileInfo
        import  s_find_currentEntry,keyboard_init,current_page
        import  NEW_CODE, boot_chaud, RAM_TOP, sd_absente, serie_brute, cz_actif

        import  video_init, init_audio, boot_jingle
        ; splash_screen (splash.asm) n'est plus lié : place pour les dossiers
        import  video_wait_vsync,PUTCHARV,video_clean, char_attribut,far_transit_buffer
        import  vsync_tick, SCREEN_START_OFFSET, DiagPut

KERNEL_LOAD_ADDR: EQU KERNEL_START

; OSMFS directory entry offsets
DE_OFF_NAME:    equ 1
DE_OFF_SIZE:    equ 20
DE_OFF_ATTR:    equ 27


;****************************************************
;* Program Code / Data Areas                        *
;****************************************************
        section .code


 ;PIA initialisation

main:

        CLR     CRA
        CLR     DDRA
        CLR     CRB
        LDA     #%11111111  ; port B en sorties
        STA     DDRB
        LDA     #%00000100  ; Configure les registres de contrôle
                            ; pour un accès simple aux registres de données
        STA     CRB
        LDA     #%00001100   ; Configuration du Registre de Contrôle A (CRA)
        STA     CRA
        LDA     #%00000000
        STA PIADRB

;TIMER initialisation

; VSYNC → IRQ 68B40 (tick 60 Hz)
; VSYNC est relié à C1 du 68B40 (MC6840). CR2=$01 sélectionne CR1, le
; registre de contrôle du timer 1 : les écritures sur $A080 vont dans CR1.
; Bits CR1 : bit0=reset interne (1=précharge compteurs + arrêt des horloges,
;            0=marche), bit1=source d'horloge (0=externe C1, 1=interne E),
;            bit6=activation IRQ, bits3-5=mode (000=continu).
; Compteur = 0 → time-out (flag Status bit 4 + IRQ) à CHAQUE front VSYNC.
; L'IRQ du 6840 est ACTIVÉE (bit6=1). handler_IRQ (IT.asm) lit le Status
; ($A081) puis le compteur T1 pour effacer le flag (IRQ niveau → sinon elle
; reste collée à 0), puis incrémente vsync_tick.
        LDA     #$01             ; sélection CR1 (timer 1)
        STA     CR2              ; CR2 ($A081) = registre de sélection
        LDX     #$0000           ; compte = 0 → time-out sur chaque front VSYNC
        STX     TIMER1           ; charge les latches MSB/LSB ($A082/$A083)
        LDA     #$41             ; bit0=reset(précharge compteur) + bit6=IRQ
        STA     CR1              ;   + bit1=0 → horloge externe C1
        LDA     #$40             ; bit0=0 : libération du reset → compteur actif
        STA     CR1
        jsr     init_audio

        LDX     #input_buffer
        STX     read_line_ptr
        STX     write_line_ptr

        LDX     #load_buffer
        STX     read_load_ptr
        STX     write_load_ptr

;ACIA initialisation
        LDA     #$FF
        STA     CR_reg
        LDA     #%10010101              ;95   NMI à la reception RTS=0 8N1 CLK/16
        STA     CR_reg

; -------------------------------------------------------------------
        ldx #VRAM_BASE
        stx VRAM_PTR
        stx vram_line_ptr
        lda     #$02
        sta     char_attribut
        JSR     video_clean             ; efface la ram vidéo
        JSR     video_init          ; programme le CRTC (68B45)

        ; Activation de l'IRQ CPU (CLI) APRÈS l'init de tous les périphériques
        ; (PIA, 68B40, ACIA, 68B45) : on ne démasque jamais une IRQ avant que
        ; le matériel qui la génère soit configuré. I=1 au reset (ORCC #$FF
        ; dans __start). Ordre CC 6809/6309 : E F H I N Z V C → I est le bit 4
        ; ($10), ANDCC #$EF = CLI, ANDCC #$BF = CLF, ORCC #$10 = SEI.
        ANDCC   #%11101111          ; CLI : démasque IRQ (I=0)

        ;JSR     BootDiag            ; DIAGNOSTIC TEMPORAIRE (à retirer)

        Lde #01
        JSR  video_wait_vsync


        ; Une carte tout juste alimentée peut ne pas répondre encore (mise
        ; sous tension : l'init vient ~16 ms après le reset ; BOOT, plus
        ; tard, réussissait). Jusqu'à 4 essais, ~160 ms d'écart.
        LDA     #4
        STA     sd_absente          ; compteur d'essais, puis 0/1
Init_Essai:
        JSR     Init_SD_Card
        BCC     Init_Ok
        DEC     sd_absente
        BEQ     Init_Rate
        LDE     #10
        JSR     video_wait_vsync
        BRA     Init_Essai
Init_Rate:
        INC     sd_absente          ; 1 : pas de carte
        BRA     Init_Fin
Init_Ok:
        CLR     sd_absente
Init_Fin:

        JSR SD_Deselect

        JSR SD_Select
        JSR FS_Mount

        ;ANDCC   #%10111111                     ;CLI les IT FIRQ active avec sauvegarde de tous les registres

        JSR     keyboard_init


        clr current_page
        JMP     Demarrage
;************************************************************************************
;               Bootloader appel le kernel en ram system
; ===================================================================
; Demarrage - Comme un PC : OSM-VISION se lance tout seul.
; Au reset (pas après un TRAP) : jingle, bannière, puis une fenêtre d'environ
; 1 s ; une touche du clavier ou un caractère reçu sur la liaison série
; pendant ce temps mène au SECOURS. OSM-VISION qui rend la main est relancé ;
; introuvable (carte absente, fichier abîmé) : SECOURS.
; ===================================================================
Demarrage:
        CLR     serie_brute         ; un programme planté en mode brut
        CLR     cz_actif            ; ... ou dans le Terminal : console plein écran
        TST     boot_chaud
        BNE     Dm_Chaud
        JSR     boot_jingle
        LDX     #hello
        JSR     [table_function_ram+sys_PrintString]
        CLR     NEW_CODE
        LDB     #60                 ; 60 trames de 16 ms
Dm_Attente:
        PSHS    B
        LDE     #1
        JSR     video_wait_vsync
        PULS    B
        LDX     write_line_ptr      ; un caractère série ?
        CMPX    #input_buffer
        BNE     Secours
        TST     NEW_CODE            ; un code du clavier ?
        BEQ     Dm_Suiv
        CLR     NEW_CODE
        LDA     SCAN_CODE
        CMPA    #$AA                ; auto-test du clavier à la mise sous tension
        BEQ     Dm_Suiv
        CMPA    #$FA                ; acquittement
        BEQ     Dm_Suiv
        CMPA    #$F0                ; relâchement : la frappe était avant la fenêtre
        BNE     Secours
Dm_Suiv:
        DECB
        BNE     Dm_Attente
Dm_Chaud:
        CLR     boot_chaud
        TST     sd_absente          ; sans carte, inutile de chercher OSM-VISION
        LBNE    Sans_Carte
Boot_Loop:
        LDS     #RAM_TOP
        JSR     bootloader          ; revient quand OSM-VISION rend la main
        BCC     Boot_Loop
        LDX     #MsgBootEchec
        JSR     [table_function_ram+sys_PrintString]
        BRA     Secours

;               Bootloader : charge OSM-VISION en page 0, $0000, et le lance
;               Sortie : C=0 il a tourné puis rendu la main, C=1 introuvable
bootloader:
    LDX     #MsgBootloaderStart
    JSR     [table_function_ram+sys_PrintString]
    CLRA        ;page 0
    LDX     #KERNEL_FILENAME
    LDY     #KERNEL_LOAD_ADDR   ; On met l'adresse de destination dans Y
    JMP     [table_function_ram+sys_loadandexec]

; ===================================================================
; LoadKernel
; Description : Trouve et charge KERNEL à l'adresse KERNEL_LOAD_ADDR
; Entrée      : a=page 0-> 3 , y=adresse , x= pointeur sur le nom complet "NAME    EXE"
; Sortie      : Carry=0 si succès, Carry=1 si échec.
; ===================================================================
LoadandExec:
    PSHS    y,x,d
    ; --- 1. Trouver le fichier KERNEL ---

    JSR     [table_function_ram+sys_FS_FindEntry]
    BCS     LoadFile_Fail     ; Fichier non trouvé, on sort en erreur
;        LDX     #FILE_FOUND
;        JSR     [table_function_ram+sys_PrintString]

    ;LDA 0,s     ;on recupère le numéro de page
    ;JSR     [table_function_ram+sys_PrintHexChar]
    lda 0,s
    JSR     [table_function_ram+sys_pager]

    LDX     2,s    ; On remet le nom de fichier dans X
    LDY     4,s
    JSR     [table_function_ram+sys_FS_LoadFile]      ; On appelle la routine

    ; LoadFile positionne le Carry en cas d'erreur
    BCS     LoadFile_Fail

;    LDX     #MsgFileLoaded
;    JSR     [table_function_ram+sys_PrintString]         ; Affiche "Noyau charge. Lancement..."

    JSR     0,y    ; On passe la main au noyau !
;    LDX     #MsgFileReturn
;    JSR     [table_function_ram+sys_PrintString]         ; Affiche "retour au shell"
    CLRA
    JSR     [table_function_ram+sys_pager]              ; on retourne en page 0
    andcc #%11111110        ;C=0 tout v bien
    BRA LoadFile_Exit

LoadFile_Fail:
;    LDX     #MsgFileNotFound
;    JSR     [table_function_ram+sys_PrintString]        ; Affiche "KERNEL introuvable."
    ORCC    #%00000001          ; C=1, Erreur

LoadFile_Exit:

        PULS    y,x,d,pc

; ===================================================================
; Secours - Le seul moniteur de l'EPROM : LOAD (Intel hex collé sur la
; liaison série), RUN aaaa, BOOT. Atteint par une touche au démarrage, par
; Ctrl+A sur la liaison série (IT.asm), ou si OSM-VISION ne se charge pas.
; Le reste (mémoire, registres, rapport du dernier TRAP) : MONITEUR, sur la
; carte.
; ===================================================================
Secours:
        LDS     #RAM_TOP
        CLR     serie_brute         ; LOAD lit la liaison série
        CLR     cz_actif            ; console plein écran
        ANDCC   #%10101111          ; IRQ et FIRQ : l'écran en a besoin
        CLRA
        JSR     Pager               ; page 0
        LDX     #input_buffer       ; la saisie repart de zéro
        STX     read_line_ptr
        STX     write_line_ptr
        CLR     ,X
        LDX     #MsgSecours
        JSR     [table_function_ram+sys_PrintString]

Monitor_Prompt:   LDX     #prompt
        JSR     [table_function_ram+sys_PrintString]
        JSR     [table_function_ram+sys_read_line]
        CMPX    #input_buffer
        BEQ     Monitor_Prompt
        LDX     #COMMAND
Monitor_NextCmd:   LDY     #input_buffer
        JSR     CmdCompare_Loop
        BEQ     Monitor_Dispatch         ; commande found
Monitor_SkipCmd:   LDA     ,X+          ;cherche la fin de la commande
        BNE     Monitor_SkipCmd
        LEAX    $02,X         ; on passe l'adresse de la commande
        LDA     ,X
        BNE     Monitor_NextCmd         ; fin de la liste ?
        LDX     #command_error
        JSR     [table_function_ram+sys_PrintString]
        BRA     Monitor_Prompt
Monitor_Dispatch:   JSR     [,X]
        BRA     Monitor_Prompt

run_cmd: JSR     asc2hex16
        JMP     ,X

boot_cmd:                           ; BOOT : une carte a pu être insérée depuis
        JSR     Init_SD_Card
        BCS     Sans_Carte_Msg
        CLR     sd_absente
        LDS     #RAM_TOP
        LBRA    Boot_Loop
Sans_Carte:
        BSR     Sans_Carte_Msg
        LBRA    Secours
Sans_Carte_Msg:
        LDX     #MsgSansCarte
        JMP     [table_function_ram+sys_PrintString]

; Services retirés avec l'ancien moniteur (REG, LS : programmes MONITEUR
; et LS sur la carte). Leurs emplacements restent dans la table : C=1.
reg_cmd:
ls_cmd:
PrintFileName83:
        ORCC    #%00000001
        RTS

load_cmd:
        JSR     INPUT
        CMPA    #':'
        BNE     load_cmd
        JSR     load_octet      ;taille
        BEQ     Load_Done
        TFR     A,B
        JSR     load_word
        JSR     load_octet
ZE207   JSR     load_octet
        STA     ,X+
        DECB
        BNE     ZE207
        JSR     load_octet      ;checksum
        BRA     load_cmd
Load_Done:   JSR     load_word
        JSR     load_word
        JSR     INPUT
        RTS

PrintHexWord:
        PSHS d
        JSR [table_function_ram+sys_PrintHexChar]
        TFR b,a
        JSR [table_function_ram+sys_PrintHexChar]
        PULS d
        RTS


PrintString:
        PSHS    a,x
StartPrint:
        LDA     ,X+
        BEQ     EOF
        JSR     [table_function_ram+sys_PrintChar]
        BRA     StartPrint
EOF:    PULS a,x,pc


PrintCRLF:    ; Routines d'affichage que tu dois fournir
        PSHS a
        LDA     #$0A
        JSR     [table_function_ram+sys_PrintChar]
        LDA     #$0D
        JSR     [table_function_ram+sys_PrintChar]
        PULS a,pc




; PrintChar : A = caractère, à l'écran seulement (PUTCHARV). Depuis le
; 15 oct. 2026, la console n'écrit plus sur la liaison série : celle-ci est
; aux programmes (MINITEL...). Un écho renvoyé par l'autre bout (un modem)
; tombait dans la fenêtre du démarrage et ouvrait le SECOURS.
; `pshsw` / `pulsw` : W sauvé autour de PUTCHARV (PrintString en dépend).
PrintChar:
        PSHS     B
        pshsw
        ldb     char_attribut
        jsr PUTCHARV
        pulsw
        PULS     b,pc


PrintHexChar:
        PSHS     A
        LSRA
        LSRA
        LSRA
        LSRA
        JSR     HexNibble
        PULS     A
        ANDA    #$0F
HexNibble:   ADDA    #$30
        CMPA    #$39
        BLS     HexNibble_Print
        ADDA    #$07
HexNibble_Print:   JSR     [table_function_ram+sys_PrintChar]
        RTS
;*******************************************************************
; liaison série
;*******************************************************************

INPUT:  PSHS     X
        LDX     read_line_ptr
wait_char:
        LDA     ,X
        BEQ     wait_char
        CLR     ,X+
        TST     ,X
        BNE     input_end
        LDX     #input_buffer+40
        STX     write_line_ptr
input_end:
        STX     read_line_ptr
        PULS     X
        RTS




; ===================================================================
; read_line - Lit une ligne clavier et la place dans input_buffer
; Entrée : rien          Sortie : A, X, B, D, U, Y, CC modifiés
;          (aucune valeur de retour n'est exploitée par les appelants)
;
; NE PAS REECRIRE CE BLOC. Les instructions ci-dessous sont restaurees
; OCTET POUR OCTET depuis bios.bin (c33393ce), la derniere EPROM ou la
; saisie multi-caracteres fonctionnait : le moniteur y acceptait "BOOT".
;
; Une version anterieure (borne + effacement d'entree) produisait un
; symptome tres deceptive : le moniteur rejouait son prompt sans message
; d'erreur. Malgre des octets corrects et un flux d'instructions coherent,
; le comportement etait faux. La reference fonctionnelle tranche : on lui
; colle. Toute "amelioration" ici doit d'abord etre verifiee sur materiel.
;
; Risque connu et assume : `STA ,X+` n'est pas borne. Une ligne de plus de
; MAX_INPUT_LEN caracteres ecraserait read_line_ptr/write_line_ptr, buffer,
; sd_ctrl puis SD_BUFFER, et laisserait input_buffer sans NUL
; (FindEndOfCmd du shell parcourrait alors la BSS sans fin). A traiter
; apres le bug de gel video, pas avant.
; ===================================================================

read_line:
        LDX     #input_buffer
ReadLine_Loop:   JSR     [table_function_ram+sys_scan_keyboard]
        TSTA
        BEQ     ReadLine_Loop
        CMPA    #$0D
        BEQ     ReadLine_Done
        CMPA    #$0A
        BEQ     ReadLine_Done
        JSR     [table_function_ram+sys_PrintChar]
        CMPA    #$60
        BLS     ReadLine_Upper
        SUBA    #' '
ReadLine_Upper:   CMPA    #$08
        BNE     ReadLine_Store
        CMPX    #input_buffer
        BEQ     ReadLine_Loop
        CLRA
        STA     ,-X
        BRA     ReadLine_Loop
ReadLine_Store:   STA     ,X+
        CLRA
        STA     ,X
        BRA     ReadLine_Loop
ReadLine_Done:   RTS

load_octet:
        PSHS     B
        JSR     INPUT
        TFR     A,B
        JSR     INPUT
        EXG     A,B
        JSR     asc2hex8
        PULS     B
        RTS

load_word:
        PSHS     A,B
        JSR     load_octet
        TFR     A,B
        JSR     load_octet
        EXG     A,B
        TFR     D,X
        PULS     A,B
        RTS

asc2hex8:
        CMPA    #$60        ;minuscule ?
        BLS     majuscule
        SUBA    #$20
majuscule:
        SUBA    #$30
        CMPA    #$09         ;chiffre 0-9?
        BLS     chiffre
        SUBA    #$07         ;A-F
chiffre:
        ASLA
        ASLA
        ASLA
        ASLA
        CMPB    #$60
        BLS     Asc2Hex_Maj2
        SUBB    #$20
Asc2Hex_Maj2:   SUBB    #$30
        CMPB    #$09
        BLS     AscHex_Merge
        SUBB    #$07
AscHex_Merge:   PSHS     B
        ORA     ,S+
        RTS

Asc2Hex_Fetch:   LDD     ,Y++
        JSR     asc2hex8
        RTS

asc2hex16:
        JSR     Asc2Hex_Fetch
        PSHS     A
        JSR     Asc2Hex_Fetch
        TFR     A,B
        PULS     A
        TFR     D,X
        RTS

;*************************************************
; entrée: X=COMMAND  Y=input_buffer
; sortie: A= 0 found Y= adresse argument
;*************************************************

CmdCompare_Loop:   LDA     ,X+
        LDB     ,Y
        CMPA    ,Y+
        BNE     CmdCompare_Done
        TSTA          ;fin de ligne
        BNE     CmdCompare_Loop
CmdCompare_Done:   PSHS     B                 ; test si B=" " et A=0
        ORA     ,S+
        ANDA    #%11011111  ;$DF
        RTS


Pager:
        STA pager_reg
        STA current_page
        RTS
; ===================================================================
; sys_FarRead - Lit un bloc de données depuis une autre page
; Entrée : A = Page Source, B = Page Dest, X = Ptr Source, Y = Ptr Dest, U = Taille
; ===================================================================
FarRead:
        PSHS    d,x,y,u,cc      ; (9 octets) S+0=CC, S+1=A(Src), S+2=B(Dst)...
        pshsw                   ; (2 octets) S+2=CC, S+3=A, S+4=B
        ORCC    #%01010000      ; CRITIQUE : Désactive les interruptions IRQ/FIRQ

        CMPU    #0
        LBEQ    FarRead_Done

FarRead_Loop:
        ; --- Calcul de la taille du bloc (Max 64 octets) ---
        CMPU    #256
        BLO     FarRead_Last
        LDW     #256             ; C'est un bloc complet de 64 octets
        BRA     FarRead_Go
FarRead_Last:
        TFR     u,w             ; C'est le dernier bloc (reste de la division)

FarRead_Go:
        PSHSW               ; SAUVEGARDE la taille du bloc (TFM détruit W)
                                ; Décalage pile : S+5 = A (Source), S+6 = B (Dest)

        ; --- 1. Page Lointaine (Source) -> Buffer ---
        LDA     5,S             ; Récupère la Page Source
        STA     $A0C0
        PSHS    y               ; Protège le pointeur de destination final
        LDY     #far_transit_buffer
        TFM     X+,Y+           ; [6309] Copie X vers Y, X avance tout seul !
        PULS    y               ; Restaure le pointeur de destination

        ; --- 2. Buffer -> Page Locale (Dest) ---
        LDA     6,S             ; Récupère la Page Destination
        STA     $A0C0
        PSHS    x               ; Protège le pointeur source
        LDX     #far_transit_buffer
        LDW     2,S             ; Recharge la taille du bloc depuis la pile
        TFM     X+,Y+           ; [6309] Copie X vers Y, Y avance tout seul !
        PULS    x               ; Restaure le pointeur source

        ; --- 3. Décrémentation de la taille totale (U) ---
        PULS    d               ; D = taille du bloc qu'on vient de traiter (ancien W)
        PSHS    d               ; On le repousse pour la soustraction
        TFR     u,d             ; D = Taille totale restante
        SUBD    ,S++            ; Soustrait la taille du bloc et nettoie la pile
        TFR     d,u             ; U = Nouvelle taille restante

        CMPU    #0
        BNE     FarRead_Loop

FarRead_Done:
        ; Sécurité : on verrouille sur la page de destination (B)
        LDA     4,S
        STA     $A0C0
        pulsw
        PULS    d,x,y,u,cc,pc

; ===================================================================
; sys_FarWrite - Écrit un bloc de données vers une autre page
; Entrée : A = Page Dest, B = Page Source, X = Ptr Source, Y = Ptr Dest, U = Taille
; ===================================================================
FarWrite:
        PSHS    d,x,y,u,cc
        pshsw                   ; S+3=A(Dest), S+4=B(Source)
        ORCC    #%01010000

        CMPU    #0
        LBEQ    FarWrite_Done

FarWrite_Loop:
        CMPU    #256
        BLO     FarWrite_Last
        LDW     #256
        BRA     FarWrite_Go
FarWrite_Last:
        TFR     u,w

FarWrite_Go:
        PSHSW               ; S+5=A(Dest), S+6=B(Source)

        ; --- 1. Page Locale (Source) -> Buffer ---
        LDA     6,S             ; Récupère la Page Source (B)
        STA     $A0C0
        PSHS    y
        LDY     #far_transit_buffer
        TFM     X+,Y+           ; X avance
        PULS    y

        ; --- 2. Buffer -> Page Lointaine (Dest) ---
        LDA     5,S             ; Récupère la Page Destination (A)
        STA     $A0C0
        PSHS    x
        LDX     #far_transit_buffer
        LDW     2,S             ; Recharge la taille du bloc
        TFM     X+,Y+           ; Y avance
        PULS    x

        ; --- 3. Mise à jour ---
        PULS    d
        PSHS    d
        TFR     u,d
        SUBD    ,S++
        TFR     d,u

        CMPU    #0
        BNE     FarWrite_Loop

FarWrite_Done:
        ; Sécurité : on verrouille sur la page source locale (B)
        LDA     4,S
        STA     $A0C0
        pulsw
        PULS    d,x,y,u,cc,pc
;--------------------------------------------------------------------------

COMMAND:
        FCN     "LOAD"
        FDB     load_cmd
        FCN     "RUN"
        FDB     run_cmd
        FCN     "BOOT"
        FDB     boot_cmd
        FCB     00

hello:   FCB     $0A,$0D
        FCC     "OSM39 V4.00   (une touche : SECOURS)"
        FCB     $0A,$0D,00
prompt:  FCB     $0D,$0A
        FCN     "SECOURS>"
command_error:
        FCN     "commande inconnue : LOAD, RUN aaaa, BOOT"
MsgSecours:
        FCB     $0A,$0D
        FCC     "SECOURS : LOAD (Intel hex sur la liaison serie), RUN aaaa, BOOT"
        FCB     $0A,$0D,0
MsgSansCarte:
        FCC     "Carte SD absente ou muette."
        FCB     $0A,$0D,0
MsgBootEchec:
        FCC     "OSMVISION introuvable."
        FCB     $0A,$0D,0

    ; --- Constantes de configuration du bootloader ---
KERNEL_FILENAME:    FCC "OSMVISION      "  ; 15 car., pad espaces (plus d'extension)
                    FCB 0
; --- Données ---
MsgBootloaderStart: FCB $0C
                    FCC "Bootloader v1.0..."
                    FCB $0a,$0D,0


        END
