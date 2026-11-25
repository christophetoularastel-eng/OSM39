; Auto-generated from bios/ram.map by update_includes.py
; Do not edit manually; rebuild the BIOS to refresh these addresses.

;vecteurs d'interruption en RAM : section .ram_vectors, fixee a $DFF0
;par l'edition de liens (bios/Makefile) ; rvec_SWI3 en est le premier mot
rvec_SWI3   equ $DFF0
rvec_IRQ    equ $DFF6
;pagination
pager_reg       equ $A0C0
;PIA
CRA         equ $A042
CRB         equ $A043
PIADRA      equ $A040
DDRA        equ $A040
PIADRB      equ $A041
DDRB        equ $A041
;ACIA
CR_reg      equ $A000
SR          equ $A000
TDR         equ $A001
RDR         equ $A001
CR_key      equ $A180
SR_key      equ $A180
TDR_key     equ $A181
RDR_key     equ $A181
;SD-KBD-SON : SPI materiel de la carte SD
SD_CTRL     equ $A140
SD_DATA     equ $A148
;SD-KBD-SON : AY-3-8910 (ecrire AY_ADR : choix du registre ; lire AY_ADR : sa valeur)
AY_ADR      equ $A150
AY_DATA     equ $A151
;TIMER
CR1         equ $A080
CR2         equ $A081
STATUS      equ $A081
CR3         equ $A080
TIMER1      equ $A082
TIMER2      equ $A084
TIMER3      equ $A086
;VIDEO
CRTC_RS     equ $A100
CRTC_DATA   equ $A101
VRAM_CTRL   equ $A120
VRAM_BASE   equ $8000
;CARTE mono : VRAM entrelacee, case c = caractere en $8000+2c, couleur
;en $8001+2c (A0 choisit la RAM). Les boucles de cases avancent de
;VRAM_PAS ; VRAM_END et VRAM_COL_END bornent ces boucles. VRAM_CTRL :
;page D0-D2, D3 = GRAPH (mode graphique : a laisser a 0).
CARTE_MONO  equ 1
VRAM_PAS    equ 2
VRAM_LIGNE  equ 160
VRAM_END    equ $A000
VRAM_COL    equ $8001
VRAM_COL_END equ $A001
VRAM_COL_OFS equ 1
;Passerelle entre pages (bios/farcall.asm), table de sauts FIXE en EPROM
FAR_CALL    equ $FFE0
FAR_CALLN   equ $FFE3
KERNEL_START    equ $0000
RAM_START   equ     $c000
RAM_TOP     equ     $dFeF

table_function_ram:       equ $C000
input_buffer:       equ $C187
NEW_CODE:       equ $C061
SCAN_CODE:       equ $C060
vsync_tick:       equ $C4C2
MUSIC_PTR:       equ $C6CD
SND_BUF:       equ $C7F2
argc:       equ $C4C0
argv:       equ $C4AC
FormattedName:       equ $C482
current_page:       equ $C4C1
; page_copy_src_bank: not found in map
; page_copy_dst_bank: not found in map
; page_copy_offset: not found in map
; page_copy_count: not found in map
; page_copy_saved_page: not found in map
; page_copy_tmp: not found in map
BUF_HEAD:       equ $C4C4
ecran_abime:       equ $CCE5
BUF_TAIL:       equ $C4C5
VRAM_PTR:       equ $C4C6
CUR_PAGE:       equ $C4C8
ASCII_BUF:       equ $C4CB
COLOR_BUF:       equ $C5CB
vram_line_ptr:       equ $C4C9
char_attribut:       equ $C6D0
g_find_fileInfo:       equ $C43D
trap_frame:       equ $C6D1
trap_info:       equ $C8EA
son_coupe:       equ $C90B
serie_brute:       equ $C90C
serie_tete:       equ $C90D
serie_queue:       equ $C90E
serie_buf:       equ $C90F
kbd_echap:       equ $CA2E
gfx_tampon:       equ $CA2F
kbd_tete:       equ $CA1F
kbd_queue:       equ $CA20
kbd_apres_f0:       equ $CA21
e0_received:       equ $C4A8
kbd_buf:       equ $CA0F
cz_actif:       equ $CA22
cz_l:       equ $CA23
cz_h:       equ $CA24
cz_haut:       equ $CA25
cz_op:       equ $CA29

