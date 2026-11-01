# ===================================================================
# Makefile — Assembleur OSM09 (ASM)
# Assembleur 2 passes compatible lwasm s'exécutant sur la machine
# ===================================================================

AS = lwasm
LD = lwlink
OBJCOPY = objcopy

ASFLAGS = --format=obj --6309 -I../bios -I../lib
LDFLAGS = --format=raw --section-base=.code=0x0000

all: ASM

ASM: asm.asm asm.o
	$(LD) $(LDFLAGS) --map=ASM.map -o ASM asm.o
	$(OBJCOPY) -I binary -O ihex ASM asm.hex

asm.o: asm.asm opcodes.inc ../lib/bioslib.asm ../bios/hardware.inc ../bios/sysfunc.inc
	$(AS) $(ASFLAGS) --list=asm.lst -o $@ $<

# ⚠ NE PAS `rm -f *.bin` ICI.
#
# Les `asm/test*.bin` ne sont PAS des produits de build : ce sont les
# BINAIRES DE REFERENCE de `emu6809.py --selftest`, versionnes dans git,
# et ils DOIVENT rester identiques octet pour octet a
#     lwasm --format=raw --6809 -o <t>.bin test/<t>.asm
# (AGENTS.md, section Emulateur). Un `make clean` a la racine les a
# supprimes le 2 octobre 2026 ; il a fallu un `git checkout` pour les
# ransomener, et le seul signe que quelque chose clochait etait
#     git status : D asm/test1.bin
# que rien dans le build ne signale.
#
# Troisieme instance de la meme famille -- voir `cmd/Makefile clean`
# (oublie `RM`) et `basic69/Makefile clean` (oublie `BASIC`/`basic.hex`).
# La regle generale : quand un build peut produire DEUX fichiers
# differents sous un meme nom, ou quand un `clean` touche des fichiers
# versionnes, c'est la TAILLE et `git status` qu'on regarde, pas le code
# de sortie de `make`.
clean:
	rm -f *.o *.lst *.map *.hex ASM

.PHONY: all clean
