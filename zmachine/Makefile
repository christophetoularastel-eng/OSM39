# ===================================================================
# Makefile - zmachine/ : l'interpréteur Z-machine (application d'OSM-VISION)
# ===================================================================
# Lié à $0000, page 1, App_Start à l'offset 0. Le code (et ses variables)
# doit finir avant ZONE ($3800) : au-delà, la pile Z et les tampons.
# zmachine_data.inc est GÉNÉRÉ par tools/zmachine/zmachine.py --inc.
# ===================================================================
AS = lwasm
LD = lwlink
ASFLAGS = --format=obj --6309 -I../bios
LDFLAGS = --format=raw --section-base=.code=0x0000
SOURCES = zmachine.asm zm_memoire.asm zm_ecran.asm zm_texte.asm zm_fichier.asm zmachine_data.inc
ZONE = 14336

all: ZMACHINE

ZMACHINE: zmachine.o
	$(LD) $(LDFLAGS) --map=$@.map -o $@ $<
	@taille=$$(stat -c %s $@); echo "  ZMACHINE : $$taille octets (ZONE : $(ZONE))"; \
	 if [ $$taille -gt $(ZONE) ]; then echo "ERREUR : ZMACHINE dépasse ZONE" >&2; mv $@ $@.trop; exit 1; fi

zmachine.o: $(SOURCES) ../bios/hardware.inc ../bios/sysfunc.inc ../lib/ui.inc
	$(AS) $(ASFLAGS) --list=zmachine.lst -o $@ $<
	@off=$$(grep -oE '^[[:xdigit:]]{4} .*[[:space:]]App_Start:' zmachine.lst | head -1 | grep -oE '^[[:xdigit:]]{4}'); \
	 if [ "$$off" != "0000" ]; then echo "ERREUR : App_Start à l'offset '$$off'" >&2; exit 1; fi; \
	 echo "  App_Start : offset 0000, OK"

zmachine_data.inc: ../tools/zmachine/zmachine.py
	python3 ../tools/zmachine/zmachine.py --inc $@

clean:
	$(RM) zmachine.o zmachine.lst ZMACHINE ZMACHINE.map ZMACHINE.trop

.PHONY: all clean
