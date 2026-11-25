; ext.inc - Les vecteurs vers BIOS2 (ext.asm) : décalages dans ExtV (RAM).
; Une souche de l'EPROM saute par [ExtV+n] ; Ext_Defauts y met au reset
; une valeur sans BIOS2 (service absent, rien, suite de l'IRQ), Ext_Entree
; (BIOS2) celle de sa routine. Même ordre que Ext_Def et Ext_Table.
EXTV_SAVE       equ 0
EXTV_DELETE     equ 2
EXTV_SETATTR    equ 4
EXTV_RENAME     equ 6
EXTV_SETLOAD    equ 8
EXTV_MKDIR      equ 10
EXTV_LISTROOT   equ 12
EXTV_CZONE      equ 14
EXTV_SNDPLAY    equ 16
EXTV_SNDSTOP    equ 18
EXTV_JINGLE     equ 20
EXTV_ZONEIRQ    equ 22
EXTV_AUDIO      equ 24
EXTV_ZONECLS    equ 26
EXTV_GRAPHE     equ 28
EXTV_GRIRQ      equ 30
EXTV_N          equ 16
