# ===================================================================
# Makefile DÉFINITIF V2 pour le projet OSM09
# ===================================================================

AS = lwasm
LD = lwlink
OBJCOPY = objcopy

SOURCES = forth.asm
OBJECTS = $(SOURCES:.asm=.o)

ASFLAGS = --format=obj --6309

# --- Options pour l'éditeur  de liens (LDFLAGS) ---
# ON AJOUTE --format=srec ICI
LDFLAGS = --format=raw --map=$(TARGET_EXE).map \
          --section-base=.code=0x0000



# Fichiers cibles
TARGET_EXE = FORTH
TARGET_HEX = forth.hex

# La règle par défaut : on veut le binaire ET le hex
all: $(TARGET_EXE) $(TARGET_HEX)

# Étape 1 : Lier les objets pour créer le fichier binaire (raw)
$(TARGET_EXE): $(OBJECTS)
	@echo "Édition des liens vers le format bin..."
	$(LD) $(LDFLAGS) -o $@ $^

# Étape 2 : Convertir le binaire en .hex (Intel Hex)
$(TARGET_HEX): $(TARGET_EXE)
	@echo "Conversion en format HEX..."
	$(OBJCOPY) -I binary -O ihex $(TARGET_EXE) $@


# Règle générique pour assembler les .asm en .o (version mise à jour)
%.o: %.asm ../bios/hardware.inc ../bios/sysfunc.inc
	@echo "Assemblage de $<..."
	$(AS) $(ASFLAGS) --list=$*.lst -o $@ $<

# Nettoyage (on ajoute .srec)
clean:
	@echo "Nettoyage du projet..."
	rm -f $(OBJECTS) *.map FORTH FORTH.EXE forth.hex

.PHONY: all clean
