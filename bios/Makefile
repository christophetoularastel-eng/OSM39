

# ===================================================================
# Makefile DÉFINITIF V2 pour le projet OSM09
# ===================================================================

AS = lwasm
LD = lwlink
PYTHON = python3
GENERATOR = ./update_includes.py

# Fichier binaire final, prêt à être gravé
TARGET_EPROM = osm39.bin
# Fichier intermédiaire au format S-Record (contient les adresses)
TARGET_LINKED = osm39.srec
TARGET_DEBUG = osm39.hex
SOURCES =  vectors.asm main.asm SD.asm keyboard.asm IT.asm ram.asm osmfs.asm filename.asm video.asm audio.asm farcall.asm
OBJECTS = $(SOURCES:.asm=.o)

ASFLAGS = --format=obj --6309

# Base address for EPROM
EPROM_BASE = 0xe000

# --- Options pour l'éditeur de liens (LDFLAGS) ---
LDFLAGS = --format=srec --map=$(TARGET_LINKED:.srec=.map) \
          --section-base=.code=$(EPROM_BASE) \
          --section-base=.vectors=0xfff0 \
          --section-base=.romjmp=0xffe0 \
          --section-base=.ram_vectors=0xdff0 \
          --section-base=.bss=0xc000

LDFLAGSDEBUG = --format=ihex --map=$(TARGET_DEBUG:.hex=.map) \
          --section-base=.code=0x0000 \
          --section-base=.vectors=0x1FF0 \
          --section-base=.romjmp=0x1FE0 \
          --section-base=.ram_vectors=0xdff0 \
          --section-base=.bss=0xc000

# La règle par défaut : on veut le fichier EPROM final
all: $(TARGET_EPROM)

# Étape 1b : Filtrer les vecteurs RAM (0xDFF2-0xDFFF) du S-Record
$(TARGET_LINKED:.srec=.filtered.srec): $(TARGET_LINKED)
	@echo "Filtrage des vecteurs RAM..."
	@grep -vE "^S10FDFF2|^S[0-9]3DFF2" $(TARGET_LINKED) > $(TARGET_LINKED:.srec=.filtered.srec)

# Étape 1a : Édition de liens vers le format S-Record
$(TARGET_LINKED): $(OBJECTS)
	@echo "Édition de liens vers le format S-Record..."
	$(LD) $(LDFLAGS) -o $@ $^

# --- layout RAM ---
# hardware.inc ET sysfunc.inc sont generes depuis la map de ram.o SEUL (et non
# du lien complet) : ram.asm est la source de verite du layout $C000.
# Ainsi un changement de ram.asm reconstruit ram.o -> ram.map ->
# hardware.inc + sysfunc.inc -> tous les modules qui les incluent, sans cycle
# *.inc <- ram.map <- ram.o <- *.inc.
# Le generateur verifie aussi que l'ordre et le nombre des sys_* (ram.asm)
# correspondent a table_function_rom (vectors.asm).
ram.map: ram.o
	@echo "Génération de la map RAM depuis ram.o..."
	$(LD) --format=srec --section-base=.bss=0xc000 --entry=0 --map=$@ -o ram.srec ram.o

# Cible groupee `&:` (GNU Make >= 4.3) : une seule execution produit les deux
# fichiers, et ils se reconstruisent ensemble.
#
# Le generateur n'ecrit QUE si le contenu change, pour ne pas Cascadee une
# re-compilation de tous les modules qui incluent ces .inc (ils sont tous
# dependants de sysfunc.inc et hardware.inc). Consequence assumee : make
# considere la cible perimee a chaque invocation et relance le generateur
# (~30 ms, ecriture nulle, 0 reassemblage). C'etait deja le comportement
# d'origine pour hardware.inc. NE PAS "corriger" cela en faisant toucher les
# fichiers : cela declencherait un rebuild complet a chaque `make`.
hardware.inc sysfunc.inc &: ram.map vectors.asm $(GENERATOR)
	@echo "Génération de hardware.inc et sysfunc.inc à partir de ram.map..."
	$(PYTHON) $(GENERATOR) ram.map vectors.asm hardware.inc sysfunc.inc

# Étape 2 : Créer l'image EPROM finale à partir du fichier S-Record filtré
$(TARGET_EPROM): $(TARGET_LINKED:.srec=.filtered.srec) hardware.inc
	@echo "Conversion SREC vers binary..."
	@# Le code doit finir avant la table de sauts fixe ($$FFE0) : au-delà,
	@# lwlink déborde en silence ($$10000...) et l'image perd la fin.
	@fin=$$(grep -E '^Section: \.code ' $(TARGET_LINKED:.srec=.map) \
	    | sed -E 's/.* load at ([0-9A-Fa-f]+), length ([0-9A-Fa-f]+)/\1 \2/' \
	    | while read a l; do printf '%d\n' $$((0x$$a + 0x$$l)); done | sort -n | tail -1); \
	if [ "$$fin" -gt $$((0xFFE0)) ]; then \
	    printf 'ERREUR : le code du BIOS finit en $$%04X, au-delà de $$FFE0\n' $$fin >&2; exit 1; \
	fi; printf 'Fin du code BIOS : $$%04X (place libre jusqu a $$FFDF : %d octets)\n' $$((fin - 1)) $$((0xFFE0 - fin))
	@python3 srec2bin.py $(TARGET_LINKED:.srec=.filtered.srec) $(TARGET_EPROM)

$(TARGET_DEBUG): $(OBJECTS)
	@echo "Édition des liens vers le format hex intel..."
	$(LD) $(LDFLAGSDEBUG) -o $@ $^

# Règle générique pour assembler les .asm en .o (version mise à jour)
%.o: %.asm sysfunc.inc hardware.inc
	@echo "Assemblage de $<..."
	$(AS) $(ASFLAGS) --list=$*.lst -o $@ $<

# ram.o définit le layout : il ne DOIT PAS dépendre de hardware.inc ni de
# sysfunc.inc (sinon le cycle *.inc <- ram.map <- ram.o <- *.inc rendrait le
# build dépendant de l'ordre des timestamps). Les deux .inc sont régénérés
# DEPUIS ram.map, donc après ram.o. ram.asm n'inclut aucun des deux.
ram.o: ram.asm
	@echo "Assemblage de $<..."
	$(AS) $(ASFLAGS) --list=$*.lst -o $@ $<

# Nettoyage
clean:
	@echo "Nettoyage du projet..."
	rm -f $(OBJECTS) $(TARGET_LINKED) $(TARGET_LINKED:.srec=.filtered.srec) $(TARGET_EPROM) *.map ram.srec hardware.inc sysfunc.inc

.PHONY: all clean
