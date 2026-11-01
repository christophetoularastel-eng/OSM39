# ===================================================================
# Makefile - apps/ : applications d'OSM-VISION (attribut a)
# ===================================================================
# Une application est liée à $0000 et tourne dans SA page (page 1) :
# OSM-VISION, en page 0, la charge et l'appelle par FAR_CALL ; elle rend la
# main par RTS. Elle dessine par les services vis_* (lib/vis.inc), dont
# elle emporte la copie (lib/vision.asm).
#
# MIRE est l'application modèle : partir de mire.asm pour en écrire une.
# ===================================================================

AS = lwasm
LD = lwlink

ASFLAGS = --format=obj --6309
LDFLAGS = --format=raw --section-base=.code=0x0000

APPS = MIRE ENVAHIS CALC EDIT GLOUTON SON PAROLE PONT MINITEL DONJON39
# Modules de page (passerelle FAR_CALLN) : liés à $0000, table de
# fonctions en tête, chargés en page 2 ou 3 par l'application.
MODULES = PONT2 PONT3

all: $(APPS) $(MODULES)

MIRE: mire.o
	$(LD) $(LDFLAGS) --map=$@.map -o $@ $<

ENVAHIS: envahis.o
	$(LD) $(LDFLAGS) --map=$@.map -o $@ $<

CALC: calc.o
	$(LD) $(LDFLAGS) --map=$@.map -o $@ $<

EDIT: edit.o
	$(LD) $(LDFLAGS) --map=$@.map -o $@ $<

GLOUTON: glouton.o
	$(LD) $(LDFLAGS) --map=$@.map -o $@ $<

SON: son.o
	$(LD) $(LDFLAGS) --map=$@.map -o $@ $<

PONT: pont.o
	$(LD) $(LDFLAGS) --map=$@.map -o $@ $<

PONT2: pont2.o
	$(LD) --format=raw --section-base=.code=0x0000 --map=$@.map -o $@ $<

PONT3: pont3.o
	$(LD) --format=raw --section-base=.code=0x0000 --map=$@.map -o $@ $<

# Un module commence par sa table de fonctions (offset 0).
pont2.o pont3.o: %.o: %.asm ../bios/hardware.inc
	$(AS) $(ASFLAGS) --list=$*.lst -o $@ $<
	@off=$$(grep -oE '^[[:xdigit:]]{4} .*[[:space:]]Module_Table:' $*.lst | head -1 \
	       | grep -oE '^[[:xdigit:]]{4}'); \
	 if [ "$$off" != "0000" ]; then \
	   echo "ERREUR : Module_Table est à l'offset '$$off', pas 0000." >&2; exit 1; \
	 else \
	   echo "  Module_Table : offset 0000, OK"; \
	 fi

PAROLE: parole.o
	$(LD) $(LDFLAGS) --map=$@.map -o $@ $<

MINITEL: minitel.o
	$(LD) $(LDFLAGS) --map=$@.map -o $@ $<

# DONJON39 : ses tampons d'image commencent en $5000 (TAMPONS) : le code doit
# finir avant.
DONJON39: donjon39.o
	$(LD) $(LDFLAGS) --map=$@.map -o $@ $<
	@test $$(stat -c %s $@) -le 20480 || { echo "ERREUR : DONJON39 dépasse \$$5000 (tampons)" >&2; rm -f $@; exit 1; }

# Tables et carte : générées par tools/donjon39/donjon39.py --inc (versionné).
donjon39.o: donjon_data.inc

# Tables du décodeur : générées par tools/minitel/videotex.py --inc (versionné).
minitel.o: minitel_data.inc

# Phonèmes et règles : générés par tools/parole/parole.py --inc (versionné).
parole.o: parole_data.inc

# Labyrinthe et glyphes : générés par video/glyphes_glouton.py (qui écrit
# aussi la police). Le fichier généré est versionné : make ne le refait pas.
glouton.o: glout_data.inc

%.o: %.asm ../bios/hardware.inc ../bios/sysfunc.inc ../lib/ui.inc ../lib/vis.inc ../lib/vision.asm ../lib/vram.asm ../lib/snd.asm ../lib/snd.inc ../lib/str.asm
	$(AS) $(ASFLAGS) --list=$*.lst -o $@ $<
	@# GARDE-FOU : le point d'entrée DOIT être à l'offset 0 (= $0000) :
	@# OSM-VISION fait JSR sur l'adresse de l'entrée OSMFS. Un include
	@# glissé avant lui ferait démarrer l'application au milieu d'une routine.
	@off=$$(grep -oE '^[[:xdigit:]]{4} .*[[:space:]]App_Start:' $*.lst | head -1 \
	       | grep -oE '^[[:xdigit:]]{4}'); \
	 if [ "$$off" != "0000" ]; then \
	   echo "ERREUR : App_Start est à l'offset '$$off', pas 0000." >&2; exit 1; \
	 else \
	   echo "  App_Start : offset 0000, OK"; \
	 fi

clean:
	rm -f *.o *.lst *.map $(APPS) $(MODULES)

.PHONY: all clean
