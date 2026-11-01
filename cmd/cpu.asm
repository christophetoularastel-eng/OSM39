; ===================================================================
; CPU.ASM — Détecte le microprocesseur : 6809 ou HD6309
; Usage: CPU
; Charge: page 1, $0000
;
; Principe : le HD6309 possède un registre W supplémentaire, accessible
; par TFR (code registre 6). Sur un 6309, les transferts mixtes 8/16
; bits sont promus : TFR A,W = TFR D,W (W = D, octet fort = A), puis
; TFR W,A = TFR W,D : A redevient $01. Sur un 6809 réel, un TFR/EXG
; avec un code de registre non défini : la lecture de la source renvoie
; $FF et l'écriture dans la destination est ignorée. TFR W,A place donc
; $FF dans A ($FF != $01) : la détection reste fiable sur les deux.
;
; NB : assembler avec --6309 (TFR A,W / TFR W,A sont des mnemoniques
; 6309) ; les octets émis ($1F $86 / $1F $68) s'exécutent sans effet
; destructeur sur un 6809 réel.
; ===================================================================
    include "../bios/hardware.inc"
    include "../bios/sysfunc.inc"

    section .code

Start:
    PSHS    D               ; sauver D (B peut être modifié par le test)

    ; --- Test du registre W (spécifique au 6309) ---
    LDA     #$01
    TFR     A,W             ; 6309 : W = D (octet fort = A) ; 6809 : écriture ignorée
    CLRA                    ; A = 0
    TFR     W,A             ; 6309 : A = octet fort de W = $01 ; 6809 : source non définie -> $FF
    CMPA    #$01            ; 6809 : $FF != $01 ; 6309 : $01 == $01
    BEQ     Is6309

Is6809:
    LDX     #Msg6809
    BRA     PrintResult

Is6309:
    LDX     #Msg6309

PrintResult:
    JSR     [table_function_ram+sys_PrintString]
    JSR     [table_function_ram+sys_PrintCRLF]
    PULS    D               ; restaurer D
    RTS

; --- Données ---
Msg6809:    FCN "CPU: Motorola 6809"
            FCB $0a,$0D,0
Msg6309:    FCN "CPU: Hitachi HD6309"
            FCB $0a,$0D,0
